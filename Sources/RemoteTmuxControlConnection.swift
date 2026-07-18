import Foundation
import os

/// A live tmux control-mode connection to one remote session.
///
/// Spawns `ssh -tt <ControlMaster> host tmux -CC attach -t <session>` as a
/// `Process` with pipes, feeds its stdout through ``RemoteTmuxControlStreamParser``
/// (in order, via an `AsyncStream`), and exposes the mirrored topology plus a
/// live output callback. cmux owns the whole protocol here — so it never depends
/// on ghostty's (tmux-3.6-fragile) built-in Viewer, and there is no
/// command-queue desync because we issue and correlate commands ourselves.
@MainActor
final class RemoteTmuxControlConnection {
    typealias ConnectionState = RemoteTmuxConnectionState
    typealias PaneForegroundState = RemoteTmuxPaneForegroundState
    typealias Snapshot = RemoteTmuxControlConnectionSnapshot
    private typealias CommandKind = RemoteTmuxControlCommandKind
    private typealias PostAttachAction = RemoteTmuxPostAttachAction

    /// The host this connection talks to.
    let host: RemoteTmuxHost
    /// The tmux session name this connection attaches to. Mutable because a
    /// `rename-session` changes it (the underlying `$id` is stable).
    private(set) var sessionName: String
    /// The tmux target used for initial attach and reconnect. Discovery-backed
    /// connections use `$id`, while create/name-only entrypoints fall back to the
    /// display name until tmux reports a stable id.
    private(set) var attachTarget: String

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

    /// Opaque token identifying a registered observer (pass to ``removeObserver(_:)``).
    typealias ObserverToken = UUID

    /// Multicast observer registry. A single connection is shared by every consumer
    /// of the same host+session (``RemoteTmuxController.attach`` reuses it), so events
    /// fan out to all consumers via this registry.
    private let observers = RemoteTmuxConnectionObservers()

    // MARK: Observed state

    private(set) var started = false
    private(set) var enterReceived = false
    /// The connection's lifecycle phase. Drives reconnect-on-transport-loss and the
    /// disconnected UI; `exited` is derived from it.
    private(set) var connectionState: ConnectionState = .connecting {
        didSet {
            guard oldValue != connectionState else { return }
            observers.notifyStateChanged(connectionState)
            switch connectionState {
            case .connected:
                finishConnectionWaiters(connected: true)
            case .ended:
                finishConnectionWaiters(connected: false)
            case .connecting, .reconnecting:
                break
            }
        }
    }
    /// `true` once the connection has permanently ended (genuine tmux `%exit`, a
    /// session discovered gone on reconnect, or a deliberate ``stop()``). A
    /// transient transport loss is `.reconnecting`, NOT ended — so callers that
    /// guard on `!exited` keep treating a reconnecting connection as alive.
    var exited: Bool { connectionState == .ended }
    private(set) var sessionId: Int?
    private(set) var windowsByID: [Int: RemoteTmuxWindow] = [:]
    private(set) var windowOrder: [Int] = []
    private(set) var activePaneByWindow: [Int: Int] = [:]
    private(set) var paneOutputByteCounts: [Int: Int] = [:]
    private(set) var totalOutputBytes = 0
    /// Last-known foreground classification per pane, kept current by the same
    /// one-shot query + live subscription that drive reflow classification
    /// (`#{alternate_on}` + `#{pane_current_command}`, see
    /// ``requestPaneReflow(paneId:)``). Read at close time to decide whether
    /// killing a mirrored pane/window needs a confirmation dialog — a mirror
    /// surface has no local child process for ghostty's needs-confirm check.
    private(set) var paneForegroundStates: [Int: PaneForegroundState] = [:]
    /// In-flight close-time activity queries by token (see
    /// ``queryWindowActivity(windowId:completion:)``). Failed with `nil` when the
    /// control stream becomes unusable, so a pending close decision falls back to
    /// the cached classification instead of hanging until a reconnect that may
    /// never come.
    private var activityQueryCompletions: [UUID: ([Int: PaneForegroundState]?) -> Void] = [:]

    private var process: Process?
    private var stdinWriter: RemoteTmuxControlPipeWriter?
    private var stdoutReader: FileHandle?
    private var stderrReader: FileHandle?
    private var stdoutPipeReader: RemoteTmuxStdoutPipeReader?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    /// Consumes the current spawn's stderr into `stderrBuffer`. Awaited before a
    /// failed reconnect attempt is classified, so the decision sees the complete
    /// error rather than racing the async stderr delivery.
    private var stderrTask: Task<Void, Never>?
    private var ingestTask: Task<Void, Never>?
    private var pendingCommands: [CommandKind] = []
    private var connectionWaiters: [UUID: (Bool) -> Void] = [:]
    private var panesWaitingForTmuxPrefixKey: Set<Int> = []
    /// Set only while an explicit `prefix+d` detach is in flight. tmux 3.7b
    /// emits a reason-less `%exit` for this action, so the mirror needs this
    /// local intent to distinguish detach from the session ending remotely.
    private(set) var clientDetachRequested = false
    /// `false` until the attach command's own `%begin`/`%end` block — always the
    /// FIRST block on each control stream, preceding every notification — has been
    /// consumed. That first block is matched explicitly (see the `.commandResult`
    /// dispatch) rather than by "FIFO happens to be empty", so a command that races
    /// in early (e.g. a debounced size send on a stalled link) can never have its
    /// result slot stolen by the attach block. Reset per spawn (each ssh re-attach
    /// produces a fresh attach block).
    private var attachBlockDrained = false
    private let createIfMissing: Bool

    /// Stateless pure decoders for control-mode message payloads (pane-state seed,
    /// window reorder, session-gone classification). Holds no state.
    private let decoding = RemoteTmuxControlMessageDecoding()
    /// Bounded ring of recent event labels surfaced through `remote.tmux.state`.
    private let diagnostics = RemoteTmuxConnectionDiagnostics()

    // MARK: Reconnect state

    /// The current reconnect backoff task (a single sleeping `Task` between
    /// attempts); cancelled on `stop()` / genuine end so a dead connection stops
    /// retrying.
    private var reconnectTask: Task<Void, Never>?
    /// Number of reconnect attempts since the last successful connect, driving the
    /// capped exponential backoff. Reset to 0 on a successful connect.
    private var reconnectAttemptCount = 0
    /// stderr text captured for the in-flight spawn, inspected when a reconnect
    /// attempt's process exits to tell "session genuinely gone" from "host still
    /// unreachable". Reset at the start of each spawn.
    private var stderrBuffer = ""
    /// Last client size applied via ``setClientSize(columns:rows:)``, re-applied
    /// after a reconnect so the resumed session keeps the mirror's grid instead of
    /// reverting to ssh's default 80×24.
    private var lastClientSize: (columns: Int, rows: Int)?
    private var pendingPostAttachAction: PostAttachAction?

    /// Trailing-edge debounce for `refresh-client -C`. SwiftUI layout settle makes the
    /// rendered grid oscillate (e.g. cols 154→155→156→161→…, ~15 distinct grids in
    /// ~1.3s), and each previously sent its own `refresh-client -C` → ~15 SIGWINCH /
    /// redraw storms on the remote per attach. We now coalesce them: ``setClientSize``
    /// stores the size immediately but defers the send to one shot after the size
    /// stops changing. The fired timer is also the clean "size settled" edge that
    /// consumes the one-shot attach redraw kick below.
    private var clientSizeDebounceTask: Task<Void, Never>?
    private static let clientSizeDebounceMs = 180

    /// Armed on every transition to `.connected` (first connect AND reconnect) and
    /// consumed by the first size apply that follows; see
    /// ``scheduleAttachRedrawKickIfNeeded()`` for why attach needs a redraw kick.
    private var pendingAttachRedrawKick = false
    private var attachRedrawKickTask: Task<Void, Never>?
    /// Gap between the kick's shrink push and its restore push. Must exceed tmux's
    /// pane-resize coalescing (~250 ms), otherwise the two pushes collapse into a
    /// net-zero size change and no SIGWINCH is ever delivered.
    private static let attachRedrawKickGapMs = 350

    /// Base reconnect backoff (seconds); doubled each attempt up to ``reconnectMaxDelaySeconds``.
    private static let reconnectBaseDelaySeconds: Double = 1
    /// Cap on the reconnect backoff (seconds). Retries continue indefinitely at this
    /// interval until the network returns or the session is found to be gone.
    private static let reconnectMaxDelaySeconds: Double = 10
    /// Cap on captured stderr (bytes) so a noisy/hostile remote can't grow it unbounded.
    private static let maxStderrBytes = 8 * 1024
    /// Cap queued stdin bytes while the dedicated writer is backpressured. Above
    /// this, mutations are rejected and the connection reconnects instead of
    /// accepting unbounded user input that may never reach tmux.
    private static let maxPendingStdinBytes = 256 * 1024
    /// Cap pending stdout between SSH's pipe callback and the main-actor parser.
    /// Initial attach can legitimately burst one `capture-pane -S 5000` block per
    /// mirrored pane, so the chunk cap absorbs pipe delivery jitter while the byte
    /// cap keeps worst-case memory bounded if parsing falls behind or the remote
    /// floods output. Parser byte budgets remain the control-stream corruption guard.
    private static let maxPendingStdoutBytes = 32 * 1024 * 1024
    private static let maxPendingStdoutChunks = 4096

    /// Subscription-name prefix for per-pane `pane_current_path` (`refresh-client -B`).
    /// The tmux pane id is appended so an inbound `%subscription-changed` can be
    /// routed back to its pane; defined once so the writer and reader can't drift.
    private static let cwdSubscriptionPrefix = "cmux_cwd_"

    /// Subscription-name prefix for per-pane reflow classification
    /// (`refresh-client -B`). The subscribed format is
    /// `#{alternate_on}<sep>#{pane_current_command}`; tmux emits it on subscribe
    /// and on every change, so launching/exiting an app (bash → node when claude
    /// starts) re-classifies the pane live. The tmux pane id is appended for
    /// routing, mirroring ``cwdSubscriptionPrefix``.
    private static let reflowSubscriptionPrefix = "cmux_reflow_"

    /// `ESC[?1049h` — enter the alternate screen, emitted to a mirror surface when
    /// the remote pane is on the alternate screen (see ``capturePane(paneId:)``).
    private static let altScreenEnterSequence = Data("\u{1b}[?1049h".utf8)
    private static let altScreenExitSequence = Data("\u{1b}[?1049l".utf8)

    /// How many lines of pane history `capture-pane` seeds onto a freshly mounted
    /// (or reconnected) mirror surface. Capturing scrollback — not just the visible
    /// screen — is what makes the mirrored tab scrollable from the start; without it
    /// a fresh attach has only the current screen and nothing to scroll up into.
    /// Clamped by the remote pane's `history-limit`, so short panes seed less.
    private static let scrollbackCaptureLines = 5_000

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        sessionId: Int? = nil,
        createIfMissing: Bool = false
    ) {
        self.host = host
        self.sessionName = sessionName
        self.sessionId = sessionId
        self.attachTarget = sessionId.map { "$\($0)" } ?? sessionName
        self.createIfMissing = createIfMissing
    }

    // MARK: - Observers

    /// Registers a consumer's callbacks and returns a token to deregister them.
    ///
    /// Multiple consumers (e.g. a mirrored workspace and a single-pane display
    /// tab) can observe the same shared connection concurrently; every callback
    /// fires for every event. Pass the returned token to ``removeObserver(_:)``
    /// when the consumer goes away.
    ///
    /// - Parameters:
    ///   - onPaneOutput: receives every `%output` (raw, octal-unescaped bytes).
    ///   - onPaneCwd: receives a pane's working directory (`pane_current_path`),
    ///     both the initial value and live changes (see ``requestPanePath(paneId:)``
    ///     and ``subscribePanePath(paneId:)``).
    ///   - onPaneReflow: receives a pane's reflow classification (`true` = suppress
    ///     reflow on resize for alt-screen / inline-TUI panes like claude; `false`
    ///     = a plain shell whose primary-screen scrollback may reflow), both the
    ///     initial value and live changes (see ``subscribePaneReflow(paneId:)``).
    ///   - onActivePaneChanged: fires when a window's active pane changes
    ///     (`%window-pane-changed`), so consumers can re-project per-pane state
    ///     (e.g. the active pane's directory) onto the window's tab.
    ///   - onSessionChanged: fires when tmux confirms a session name change via
    ///     `%session-changed` or `%session-renamed`.
    ///   - onTopologyChanged: fires when the window/pane topology changes.
    ///   - onExit: fires once when the connection PERMANENTLY ends (a genuine tmux
    ///     `%exit`, or a session found gone on reconnect). A transient transport loss
    ///     does NOT fire this — the connection reconnects instead.
    ///   - onConnectionStateChanged: fires on every ``ConnectionState`` transition
    ///     (e.g. `.connected` → `.reconnecting` on a transport loss), so consumers
    ///     can show a disconnected/reconnecting indicator without tearing down.
    @discardableResult
    func addObserver(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)? = nil,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)? = nil,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)? = nil,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)? = nil,
        onTopologyChanged: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onConnectionStateChanged: ((ConnectionState) -> Void)? = nil
    ) -> ObserverToken {
        observers.add(
            onPaneOutput: onPaneOutput,
            onPaneCwd: onPaneCwd,
            onPaneReflow: onPaneReflow,
            onActivePaneChanged: onActivePaneChanged,
            onSessionChanged: onSessionChanged,
            onTopologyChanged: onTopologyChanged,
            onExit: onExit,
            onConnectionStateChanged: onConnectionStateChanged
        )
    }

    /// Deregisters the callbacks registered under `token`.
    func removeObserver(_ token: ObserverToken) {
        observers.remove(token)
    }

    /// Spawns the SSH `tmux -CC` process and begins streaming.
    func start() throws {
        guard !started else { return }
        try host.ensureControlSocketDirectory()
        // The initial connect honors `createIfMissing`; reconnects never create.
        try spawnProcess(createIfMissing: createIfMissing)
        started = true
    }

    /// Suspends until the control stream really enters tmux control mode, or until
    /// the connection reaches a permanent end. Launch success alone is not enough:
    /// `ssh` can start and then fail authentication/session attach before tmux emits
    /// `%enter`.
    func waitUntilConnected() async -> Bool {
        switch connectionState {
        case .connected:
            return true
        case .ended:
            return false
        case .connecting, .reconnecting:
            break
        }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch connectionState {
                case .connected:
                    continuation.resume(returning: true)
                    return
                case .ended:
                    continuation.resume(returning: false)
                    return
                case .connecting, .reconnecting:
                    break
                }

                connectionWaiters[token] = { connected in
                    continuation.resume(returning: connected)
                }

                if Task.isCancelled {
                    finishConnectionWaiter(token, connected: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishConnectionWaiter(token, connected: false)
            }
        }
    }

    /// Spawns (or re-spawns, on reconnect) the SSH `tmux -CC` process and wires its
    /// stdout into the parser, consuming stderr for session-gone classification.
    /// Resets the per-process state (parser, pending-command FIFO, captured stderr,
    /// `enterReceived`) so a reconnect starts from a clean control stream.
    ///
    /// - Parameter createIfMissing: `true` only for the initial connect. Reconnect
    ///   attempts pass `false` (`attach-session`), so a session killed during the
    ///   outage fails the re-attach (→ `.ended`) instead of being silently recreated.
    private func spawnProcess(createIfMissing: Bool) throws {
        // Fresh control stream: the prior attempt's pending-command FIFO is stale
        // and must not bleed into the new %begin/%end correlation. (The parser is
        // per-spawn too — each ingest task owns a fresh one.)
        pendingCommands.removeAll()
        // Normally already flushed by beginReconnecting; kept here so a future
        // caller of spawnProcess can't strand a close decision.
        failPendingActivityQueries()
        attachBlockDrained = false
        panesWaitingForTmuxPrefixKey.removeAll()
        stderrBuffer = ""
        enterReceived = false

        let proc = Process()
        let invocation = host.controlProcessInvocation(
            sessionName: attachTarget,
            createIfMissing: createIfMissing
        )
        proc.executableURL = URL(fileURLWithPath: invocation.executablePath)
        proc.arguments = invocation.arguments
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let stdinWriter = RemoteTmuxControlPipeWriter(
            handle: inPipe.fileHandleForWriting,
            label: "com.cmux.remote-tmux.stdin.\(UUID().uuidString)",
            maxPendingBytes: Self.maxPendingStdinBytes,
            onFailure: { [weak self] in
                self?.handleStdinWriteFailure()
            }
        )

        let stdoutPipeReader = RemoteTmuxStdoutPipeReader(
            maxPendingChunks: Self.maxPendingStdoutChunks,
            maxPendingBytes: Self.maxPendingStdoutBytes,
            onOverflow: { [weak self] in
                self?.handleStdoutBackpressureOverflow()
            }
        )
        let reader = outPipe.fileHandleForReading
        stdoutPipeReader.attach(to: reader)
        // Capture stderr via its own AsyncStream so a failed reconnect attempt can be
        // classified deterministically: `handleStreamEnd` awaits `stderrTask` (which
        // finishes on stderr EOF) before reading `stderrBuffer`, so the decision can't
        // race a not-yet-delivered chunk.
        let (errStream, errContinuation) = AsyncStream<Data>.makeStream()
        let errReader = errPipe.fileHandleForReading
        errReader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errContinuation.finish()
            } else {
                errContinuation.yield(chunk)
            }
        }
        // Finish BOTH streams on process exit so the consumers (and any awaiter)
        // always complete even if a reader's EOF callback is delayed.
        proc.terminationHandler = { _ in
            stdoutPipeReader.close()
            errContinuation.finish()
        }

        do {
            try proc.run()
        } catch {
            // Don't latch `started` on a failed launch, so a later attach can
            // replace this connection instead of reusing a dead one. Close the
            // stdin writer too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            errReader.readabilityHandler = nil
            stdoutPipeReader.close()
            errContinuation.finish()
            stdinWriter.close()
            throw error
        }
        process = proc
        self.stdinWriter = stdinWriter
        stdoutReader = reader
        stderrReader = errReader
        self.stdoutPipeReader = stdoutPipeReader
        stderrContinuation = errContinuation
        stderrTask = Task { [weak self] in
            for await chunk in errStream {
                guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { continue }
                self?.appendStderr(text)
            }
        }
        // Parse OFF the main actor: the parser (fresh per spawn, owned by this
        // task) chews the raw control stream on a background executor and only
        // finished, Sendable messages hop to the main actor. A flooding pane
        // therefore competes with a background thread — not with typing, SwiftUI
        // layout, or Metal presentation. Delivery stays ordered because this
        // single loop awaits each main-actor batch before parsing on.
        ingestTask = Task.detached(priority: .userInitiated) { [weak self] in
            var parser = RemoteTmuxControlStreamParser()
            for await chunk in stdoutPipeReader.stream {
                let messages = parser.feed(chunk)
                stdoutPipeReader.release(chunk)
                guard !messages.isEmpty else { continue }
                guard let self else { return }
                await self.deliver(messages)
            }
            await self?.handleStreamEnd()
        }
    }

    /// Appends captured stderr, bounded (by UTF-8 bytes) so a noisy/hostile remote
    /// can't grow it without limit. Keeps the tail (the most recent, where the
    /// failure reason is).
    private func appendStderr(_ text: String) {
        stderrBuffer += text
        if stderrBuffer.utf8.count > Self.maxStderrBytes {
            stderrBuffer = String(decoding: Array(stderrBuffer.utf8.suffix(Self.maxStderrBytes)), as: UTF8.self)
        }
    }

    /// Sends a tmux command on the control stream (newline-terminated).
    @discardableResult
    func send(_ command: String) -> Bool {
        sendInternal(command, kind: .other)
    }

    /// Sizes the tmux control client to `columns`×`rows` cells (tmux
    /// `refresh-client -C`) so the remote windows/panes reflow to the rendered
    /// cmux grid. Without this a freshly attached session stays at ssh's default
    /// 80×24 and TUIs (claude, claude agents) render mangled. Always records the grid
    /// (re-applied by ``reseedAfterReconnect()``); sends the live `refresh-client`
    /// only while `.connected`. No-ops for a degenerate grid.
    ///
    /// This is the single sizing entrypoint every remote-tmux render path routes
    /// through (the single-pane display surface and the multi-pane window mirror),
    /// so client sizing stays one shared behavior rather than duplicated sends.
    func setClientSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        // Remember the grid so a reconnect can re-apply it (a fresh ssh client
        // otherwise reverts to 80×24 and mangles TUIs). Only send now when actually
        // connected — while reconnecting/ended there is no live stdin (the send would
        // silently drop); `reseedAfterReconnect` re-applies the stored size.
        lastClientSize = (columns, rows)
        guard connectionState == .connected else { return }
        // Coalesce the layout-settle oscillation into a single send: (re)arm a short
        // trailing timer; only the last size in a burst actually goes out. The fired
        // timer is also the "settled" edge that consumes the attach redraw kick.
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.clientSizeDebounceMs))
            } catch {
                return
            }
            guard let self, self.connectionState == .connected, let size = self.lastClientSize else { return }
            self.send("refresh-client -C \(size.columns)x\(size.rows)")
            // This send already applied the stored grid — the deferred first-connect
            // apply would only duplicate it (a deferred reconnect re-seed must stay).
            if self.pendingPostAttachAction == .applyClientSize {
                self.pendingPostAttachAction = nil
            }
            // Do NOT re-capture here. A re-capture would run capture-pane before the
            // remote app (claude) finishes its post-SIGWINCH redraw, snapshotting the
            // stale pre-resize frame and clobbering the correct redraw — the exact
            // narrow/overlap/duplicate mangle. A manual resize is clean precisely
            // because it issues no capture: it lets refresh-client -C → SIGWINCH →
            // the app's own redraw stream back and paint. Attach does the same.
            self.scheduleAttachRedrawKickIfNeeded()
        }
    }

    /// One-shot, attach-only: force a real SIGWINCH when the attach size push was a
    /// no-op, so a running TUI re-renders the current frame at the current width.
    ///
    /// Why this exists: tmux's grid stores an app's output as it was RENDERED — rows
    /// drawn at an earlier window width, or an inline TUI's streaming churn, stay in
    /// the visible frame verbatim. tmux has no "redraw" command for a control (-CC)
    /// client (`%output` is an append-only pty copy; tmux never re-streams grid
    /// cells), and `capture-pane` re-reads the same stale cells, so the ONLY way to
    /// get a clean current-width frame is the app's own repaint — which apps do on
    /// SIGWINCH. A real-terminal attach virtually always delivers that SIGWINCH
    /// because its size differs from the detached window's size. The mirror's attach
    /// usually does NOT: the window still has the size cmux itself left behind, so
    /// `refresh-client -C` matches it exactly, no pane resize happens, and the stale
    /// frame stays until the user manually resizes. This kick closes that one gap by
    /// sending the same signal a real attach sends: a genuine size change (rows-1),
    /// then the true size after tmux's resize-coalescing window has passed.
    ///
    /// Ordering is safe vs the seed: the kick is scheduled after the capture-pane
    /// commands, and the tmux server processes commands FIFO, so the app's redraw
    /// `%output` always lands after (on top of) the seed paint. Skipped entirely when
    /// the attach push itself changed the window size (that already SIGWINCHes), and
    /// invisible for plain-shell panes (nothing re-renders, nothing is streamed).
    private func scheduleAttachRedrawKickIfNeeded() {
        guard pendingAttachRedrawKick else { return }
        // Not ready yet (no grid computed / topology not drained): keep the one-shot
        // armed for the next size apply instead of consuming it uselessly.
        guard connectionState == .connected, let size = lastClientSize, !windowsByID.isEmpty else { return }
        pendingAttachRedrawKick = false
        guard size.rows > 2 else { return }
        // Only kick when some mirrored window ALREADY has the target size — i.e. the
        // size apply above cannot produce a SIGWINCH for it. (window-size latest makes
        // every window track the client, so one client-level kick redraws them all.)
        let windowAlreadyAtTarget = windowsByID.values.contains {
            $0.width == size.columns && $0.height == size.rows
        }
        guard windowAlreadyAtTarget else {
            #if DEBUG
            cmuxDebugLog("remote.size.kick skip=windowSizeDiffers target=\(size.columns)x\(size.rows)")
            #endif
            return
        }
        #if DEBUG
        cmuxDebugLog("remote.size.kick shrink to \(size.columns)x\(size.rows - 1)")
        #endif
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = Task { @MainActor [weak self] in
            guard let self, self.connectionState == .connected else { return }
            // Bail if the user resized since the kick was scheduled: that resize is a
            // real size change, so it already delivered the SIGWINCH this kick exists
            // to force — and a shrink at the captured (now stale) size would flash
            // wrong dimensions at the remote apps.
            guard let current = self.lastClientSize, current == size else { return }
            self.send("refresh-client -C \(size.columns)x\(size.rows - 1)")
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.attachRedrawKickGapMs))
            } catch {
                return
            }
            guard self.connectionState == .connected else { return }
            // Restore the CURRENT size (the user may have resized during the gap).
            let restore = self.lastClientSize ?? size
            #if DEBUG
            cmuxDebugLog("remote.size.kick restore to \(restore.columns)x\(restore.rows)")
            #endif
            self.send("refresh-client -C \(restore.columns)x\(restore.rows)")
        }
    }

    /// Re-sends the stored client grid immediately, bypassing the debounce and
    /// the same-size dedup. Used when cmux regains app focus: with another tmux
    /// client attached at a different size, `window-size latest` follows the
    /// last client that acted, so re-asserting on activation snaps the session
    /// back to the mirror's grid without waiting for a keystroke.
    func reassertClientSize() {
        guard connectionState == .connected, let size = lastClientSize else { return }
        send("refresh-client -C \(size.columns)x\(size.rows)")
    }

    /// Requests the current window list + layouts (used to (re)build topology).
    ///
    /// `#{window_name}` is placed last because it can contain spaces, while the
    /// id and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func requestWindows() {
        // `#{pane_id}` in list-windows context resolves to each window's
        // ACTIVE pane — the only way to learn the initial active pane, since
        // `%window-pane-changed` only fires on changes after attach.
        // `#{?window_zoomed_flag,Z,-}` is a deterministic single token (never
        // empty, unlike `#{window_flags}`), and `#{window_visible_layout}`
        // carries the zoomed rendering so a window that was ALREADY zoomed at
        // attach mirrors correctly.
        sendInternal(
            "list-windows -F \"#{window_id} #{pane_id} #{?window_zoomed_flag,Z,-} "
                + "#{window_layout} #{window_visible_layout} #{window_name}\"",
            kind: .listWindows
        )
    }

    /// Rearranges the tracked window order to reflect a just-applied reorder.
    /// `reordered` is the new sequence of a subset of windows (the ones the user
    /// dragged); windows not in it keep their slots. This is synchronous and exact
    /// — the `swap-window` commands achieve precisely this order, so it matches
    /// tmux without a round-trip, and a rapid follow-up reorder reads the
    /// just-applied order rather than a stale one. (A `list-windows` re-fetch would
    /// reintroduce the race: an earlier reorder's async snapshot could land after a
    /// later reorder and roll the order back. Out-of-band changes still reconcile
    /// via the topology events that already trigger ``requestWindows()``.)
    func applyWindowReorder(_ reordered: [Int]) {
        windowOrder = decoding.windowOrder(windowOrder, applyingReorder: reordered)
    }

    /// Captures a pane's current visible contents (with escapes) and delivers
    /// them to the pane-output observers so a freshly-mounted display surface shows
    /// the existing screen instead of starting blank.
    ///
    /// First queries `#{alternate_on}` and, if the remote pane is on the alternate
    /// screen, enters it on the mirror surface (emits `ESC[?1049h`) before the
    /// captured rows so they land on the matching screen and resize behaves like the
    /// remote (the alternate screen does not reflow).
    ///
    /// After the paint it restores terminal state the live `%output` doesn't carry
    /// (it set before cmux attached): scroll region, DEC private modes, the mouse
    /// tracking mode, and the cursor. Restoring the mouse mode means clicks, scroll,
    /// and drag in the mirror are forwarded to the remote app — so drag-to-select
    /// becomes the app's own selection/OSC 52 copy, and **Shift+drag** does a native
    /// cmux copy (exactly as a local terminal behaves with a mouse-mode app).
    func capturePane(paneId: Int) {
        // Match the remote pane's screen (primary vs alternate) BEFORE seeding the
        // captured rows. An alt-screen TUI (e.g. claude) must render on the mirror's
        // alternate screen so resize matches the remote (the alternate screen does
        // not reflow; the primary screen reflows/scrolls and offsets rows). The
        // pane was already on the alt screen before cmux attached, so its 1049h is
        // not in the live %output — query `#{alternate_on}` and enter alt ourselves.
        // Ordered first so the enter lands before the capture paint in the FIFO.
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{alternate_on}\"",
            kind: .paneAltScreen(paneId)
        )
        // `-S -<N>` seeds scrollback history (not just the visible screen) so the
        // mirrored tab is scrollable immediately on attach/reconnect. On an
        // alternate-screen pane there is no history, so tmux clamps to the visible
        // alt screen — harmless.
        //
        // NOTE: do NOT add `-J` (join wrapped lines) here. It was tried to make a
        // shell pane's PRE-ATTACH scrollback rejoin cleanly on grow, but it rewrites
        // an inline/alt-screen TUI's captured rows into different logical lines, so
        // the seed paints shifted on reattach (claude's input line lands a row off
        // and the frame doubles) and scatters on resize. The reflow win for shells
        // comes from LIVE %output (which already carries real soft-wraps), not from
        // the seed — so `-J`'s only upside (pre-attach rejoin-on-grow) isn't worth
        // corrupting every TUI seed. Capture faithful visual rows instead.
        sendInternal("capture-pane -p -e -S -\(Self.scrollbackCaptureLines) -t %\(paneId)", kind: .capturePane(paneId))
        // Query the pane's terminal STATE; tmux exposes it all as formats. Sent
        // after capture-pane so it applies on top of the painted rows (the seed
        // escapes are built in `paneStateSeedSequence`). See the doc comment for why
        // restoring this matters.
        sendInternal(
            "display-message -p -t %\(paneId) -F \""
                + "cursor_x=#{cursor_x},cursor_y=#{cursor_y},"
                + "scroll_region_upper=#{scroll_region_upper},scroll_region_lower=#{scroll_region_lower},"
                + "cursor_flag=#{cursor_flag},insert_flag=#{insert_flag},"
                + "keypad_cursor_flag=#{keypad_cursor_flag},keypad_flag=#{keypad_flag},"
                + "wrap_flag=#{wrap_flag},origin_flag=#{origin_flag},pane_height=#{pane_height},"
                + "mouse_all_flag=#{mouse_all_flag},mouse_button_flag=#{mouse_button_flag},"
                + "mouse_standard_flag=#{mouse_standard_flag},"
                + "mouse_sgr_flag=#{mouse_sgr_flag},mouse_utf8_flag=#{mouse_utf8_flag},"
                + "bracket_paste_flag=#{bracket_paste_flag}\"",
            kind: .paneState(paneId)
        )
    }

    /// Seeds (or re-seeds) a mirrored pane in the one canonical sequence: reflow
    /// classification FIRST (the one-shot query — always works — then the live
    /// subscription for re-classification, e.g. bash → node), then the content
    /// capture, then cwd tracking (initial value + live `cd`). Classification is
    /// queued before the (3-command) capture because it only matters at the next
    /// resize — the earlier it lands, the smaller the window in which a resize
    /// hits the conservative no-reflow default on a slow link.
    func seedPane(paneId: Int) {
        requestPaneReflow(paneId: paneId)
        subscribePaneReflow(paneId: paneId)
        capturePane(paneId: paneId)
        requestPanePath(paneId: paneId)
        subscribePanePath(paneId: paneId)
    }

    /// One-shot query of a pane's working directory (`pane_current_path`),
    /// delivered to the cwd observers. Guarantees an initial folder for the
    /// mirrored tab even on tmux builds without control-mode subscriptions.
    func requestPanePath(paneId: Int) {
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{pane_current_path}\"",
            kind: .panePath(paneId)
        )
    }

    /// The exact `refresh-client -B` line that subscribes `paneId`'s working
    /// directory. The `name:target:format` argument MUST stay double-quoted:
    /// tmux's command parser rejects an unquoted `#{…}` mid-argument with
    /// `parse error: syntax error` (verified on tmux 3.6a), and because the
    /// result FIFO drops `%error` blocks the subscription would silently never
    /// exist — the mirrored tab's folder would just never update.
    static func panePathSubscriptionCommand(paneId: Int) -> String {
        "refresh-client -B \"\(cwdSubscriptionPrefix)\(paneId):%\(paneId):#{pane_current_path}\""
    }

    /// Subscribes to live `pane_current_path` changes for `paneId` via tmux
    /// control-mode `refresh-client -B`, so a remote `cd` updates the mirrored
    /// tab's folder without polling. tmux emits the value once on subscribe and
    /// again on every change as `%subscription-changed cmux_cwd_<paneId> … : <path>`.
    /// Best-effort: on tmux builds that don't support subscriptions the command is
    /// a no-op and ``requestPanePath(paneId:)`` still supplies the initial folder.
    func subscribePanePath(paneId: Int) {
        send(Self.panePathSubscriptionCommand(paneId: paneId))
    }

    /// Removes the live `pane_current_path` subscription for `paneId` (issued once
    /// the pane is gone). tmux also drops a dead pane's subscriptions on its own;
    /// this keeps the client's subscription set tidy across split/close churn.
    func unsubscribePanePath(paneId: Int) {
        send("refresh-client -B \(Self.cwdSubscriptionPrefix)\(paneId)")
    }

    /// One-shot query of a pane's reflow classification (`#{alternate_on}` +
    /// `#{pane_current_command}`), delivered to the reflow observers. This is the
    /// REQUIRED initial classifier — `subscribePaneReflow` only guarantees *live*
    /// updates, and on tmux builds where the `-B` subscription doesn't deliver this
    /// combined value the surface would otherwise stay at its safe no-reflow default
    /// forever (shells never reflow). Mirrors ``requestPanePath(paneId:)`` exactly
    /// (a `display-message` always works where a subscription might not).
    func requestPaneReflow(paneId: Int) {
        sendInternal(
            "display-message -p -t %\(paneId) -F \""
                + "#{alternate_on}\(PaneForegroundState.fieldSeparator)#{pane_current_command}\"",
            kind: .paneReflow(paneId)
        )
    }

    /// Classifies a raw `#{alternate_on}|#{pane_current_command}` value (from the
    /// one-shot query or a live subscription), records it as the pane's foreground
    /// state (for the close-confirmation check), and emits the no-reflow decision.
    /// No-reflow when on the alternate screen OR the foreground command isn't a known
    /// plain shell; defaults to no-reflow on an empty/unparseable value (safe).
    private func classifyAndEmitReflow(paneId: Int, rawValue: String, source: String) {
        let state = PaneForegroundState(rawValue: rawValue)
        paneForegroundStates[paneId] = state
        let noReflow = state.suppressesReflow
        #if DEBUG
        cmuxDebugLog(
            "remote.reflow.classify pane=\(paneId) src=\(source) raw=\"\(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                + "alt=\(state.alternateOn ? 1 : 0) cmd=\"\(state.command)\" noReflow=\(noReflow ? 1 : 0)"
        )
        #endif
        observers.emitPaneReflow(paneId, noReflow)
    }

    /// The exact `refresh-client -B` line that subscribes `paneId`'s foreground
    /// classification. Same quoting requirement as
    /// ``panePathSubscriptionCommand(paneId:)`` — unquoted, tmux rejects the
    /// `#{…}` with a (silently dropped) parse error and the live classification
    /// never arrives, so a pane that starts a command after its seed keeps its
    /// stale idle-shell state and the close confirmation never fires.
    static func paneReflowSubscriptionCommand(paneId: Int) -> String {
        "refresh-client -B \"\(reflowSubscriptionPrefix)\(paneId):%\(paneId):"
            + "#{alternate_on}\(PaneForegroundState.fieldSeparator)#{pane_current_command}\""
    }

    /// Subscribes to live reflow-classification changes for `paneId` via tmux
    /// control-mode `refresh-client -B`. The subscribed value is
    /// `#{alternate_on}|#{pane_current_command}`; tmux emits it once on subscribe
    /// and again whenever it changes, so a pane that switches between a plain shell
    /// and an inline TUI (e.g. bash → node when claude launches) is reclassified
    /// without polling. The mirror surface uses this to decide whether to reflow its
    /// primary screen on resize (shells reflow; alt-screen / inline-TUI panes do
    /// not), and the close confirmation uses it to track the active foreground
    /// command. Best-effort: on tmux builds without subscriptions this is a no-op and
    /// the surface keeps its safe no-reflow default. See ``subscriptionChanged``
    /// handling for the parse, and ``PaneForegroundState/plainShellCommands`` for the policy.
    func subscribePaneReflow(paneId: Int) {
        send(Self.paneReflowSubscriptionCommand(paneId: paneId))
    }

    /// Removes the live reflow-classification subscription for `paneId` (issued once
    /// the pane is gone), mirroring ``unsubscribePanePath(paneId:)``.
    func unsubscribePaneReflow(paneId: Int) {
        send("refresh-client -B \(Self.reflowSubscriptionPrefix)\(paneId)")
    }

    /// Format for close-time activity queries: the pane id (for cache refresh and
    /// multi-pane correlation) plus the same `alternate_on`/`pane_current_command`
    /// pair the reflow subscription streams. Quoted by the command builders — see
    /// ``panePathSubscriptionCommand(paneId:)`` for why the quoting is load-bearing.
    private static let activityQueryFormat = "#{pane_id}\(PaneForegroundState.fieldSeparator)"
        + "#{alternate_on}\(PaneForegroundState.fieldSeparator)#{pane_current_command}"

    /// The `list-panes` line behind ``queryWindowActivity(windowId:completion:)``.
    static func windowActivityQueryCommand(windowId: Int) -> String {
        "list-panes -t @\(windowId) -F \"\(activityQueryFormat)\""
    }

    /// The `display-message` line behind ``queryPaneActivity(paneId:completion:)``.
    static func paneActivityQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"\(activityQueryFormat)\""
    }

    /// Live, close-time query of every pane's foreground state in `windowId`.
    /// tmux evaluates `pane_current_command` AT QUERY TIME, so a command started
    /// the instant before ⌘W is already visible — unlike the `%subscription-changed`
    /// cache, which tmux only re-checks about once a second. Results also refresh
    /// ``paneForegroundStates`` so the synchronous consumers (batch close,
    /// workspace close, quit warning) get the freshness for free. `completion` is
    /// called exactly once, on the main actor; `nil` means the query could not be
    /// issued or the stream reset first (caller falls back to the cache).
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: PaneForegroundState]?) -> Void) {
        sendActivityQuery(Self.windowActivityQueryCommand(windowId: windowId), completion: completion)
    }

    /// Single-pane variant of ``queryWindowActivity(windowId:completion:)``, for
    /// the multi-pane mirror's pane-header ✕ close.
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: PaneForegroundState]?) -> Void) {
        sendActivityQuery(Self.paneActivityQueryCommand(paneId: paneId), completion: completion)
    }

    private func sendActivityQuery(
        _ command: String, completion: @escaping ([Int: PaneForegroundState]?) -> Void
    ) {
        guard connectionState == .connected else {
            completion(nil)
            return
        }
        let token = UUID()
        activityQueryCompletions[token] = completion
        guard sendInternal(command, kind: .activityQuery(token)) else {
            // The stream could not accept the query, so no result can correlate.
            // Fail now and let the close decision proceed on the cached state.
            activityQueryCompletions.removeValue(forKey: token)?(nil)
            return
        }
    }

    /// Parses one activity-query line (``activityQueryFormat``):
    /// `%<paneId>|<alternate_on>|<pane_current_command>`. `nil` for an
    /// unparseable line — the caller treats that pane as unclassified.
    /// `maxSplits: 1` is deliberate (NOT 2): this strips only the `%paneId`
    /// prefix, and ``PaneForegroundState/init(rawValue:)`` applies its own
    /// `maxSplits: 1` for the second field — so a `|` inside a command name
    /// stays in the command instead of truncating it.
    static func parseActivityQueryLine(_ line: String) -> (paneId: Int, state: PaneForegroundState)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: PaneForegroundState.fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let paneId = RemoteTmuxControlStreamParser.id(parts[0], sigil: "%") else { return nil }
        return (paneId, PaneForegroundState(rawValue: String(parts[1])))
    }

    /// Fails every in-flight activity query — called whenever the control stream
    /// becomes unusable (reconnect begins, deliberate stop, genuine `%exit`), so
    /// a pending close decision falls back to the cached classification.
    private func failPendingActivityQueries() {
        guard !activityQueryCompletions.isEmpty else { return }
        let completions = Array(activityQueryCompletions.values)
        activityQueryCompletions.removeAll()
        for completion in completions { completion(nil) }
    }

    private func finishConnectionWaiters(connected: Bool) {
        guard !connectionWaiters.isEmpty else { return }
        let waiters = Array(connectionWaiters.values)
        connectionWaiters.removeAll()
        for waiter in waiters {
            waiter(connected)
        }
    }

    private func finishConnectionWaiter(_ token: UUID, connected: Bool) {
        connectionWaiters.removeValue(forKey: token)?(connected)
    }

    /// Sends typed bytes to a mirrored pane. Literal text stays binary-safe via
    /// `send-keys -H`; tmux prefix chords are replayed through the control
    /// client's key table so bindings like `prefix+%`, `prefix+"`, `prefix+Space`,
    /// and user customizations such as `prefix+s` keep their tmux semantics.
    ///
    /// While the transport is down (`.connecting`/`.reconnecting`) a bounded
    /// amount of input is held per pane and flushed on reconnect — a real ssh
    /// session buffers keystrokes typed during a blip rather than discarding
    /// them, and silently eating input is the worst basic-terminal-behavior
    /// violation a frozen mirror can commit. Input beyond the cap is dropped
    /// NEWEST-first so the replayed stream is a clean prefix (a truncated tail
    /// could split an escape sequence).
    @discardableResult
    func sendKeys(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        switch connectionState {
        case .connecting, .reconnecting:
            var buffer = pendingInputByPane[paneId] ?? Data()
            let room = Self.maxPendingInputBytesPerPane - buffer.count
            guard room > 0 else { return false }
            buffer.append(data.prefix(room))
            pendingInputByPane[paneId] = buffer
            return true
        case .ended:
            return false
        case .connected:
            let commands = tmuxKeyCommands(paneId: paneId, data: data)
            guard !commands.isEmpty else { return true }
            // Fast path for normal typing: when no paced work is queued and the
            // writer has room, send synchronously in this main-actor turn — the
            // keystroke pays ZERO async overhead (identical to the pre-pacing
            // path), which keeps typing latency off the async scheduler. Fall
            // back to the paced chain only when a paste is in flight
            // (outboundFlushTask != nil, preserving order — B-F2) or the writer
            // is backpressured (so the keystroke is paced, not dropped — B-F5).
            if outboundFlushTask == nil, let writer = stdinWriter {
                let byteCount = commands.reduce(0) { $0 + $1.command.utf8.count + 1 }
                if writer.hasCapacity(byteCount) {
                    for entry in commands {
                        guard sendInternal(entry.command, kind: entry.kind) else { return false }
                    }
                    return true
                }
            }
            return enqueueOutbound(commands, bounded: true)
        }
    }

    /// Typed input held while the transport was down, keyed by pane. Bounded;
    /// cleared on flush and on permanent end.
    private var pendingInputByPane: [Int: Data] = [:]
    private static let maxPendingInputBytesPerPane = 4096

    /// Replays input typed during a transport outage (called on reconnect once
    /// the stream is back in control mode; `send-keys` needs no local topology,
    /// so this is safe before the attach block drains — the FIFO correlates its
    /// replies positionally either way).
    private func flushPendingInput() {
        guard !pendingInputByPane.isEmpty else { return }
        let pending = pendingInputByPane
        pendingInputByPane.removeAll()
        for (paneId, data) in pending.sorted(by: { $0.key < $1.key }) {
            _ = enqueueOutbound(tmuxKeyCommands(paneId: paneId, data: data), bounded: true)
        }
    }

    /// Builds the ordered control commands that deliver `data` (typed keys) to
    /// `%paneId`, mutating the prefix-wait and detach-intent state synchronously.
    /// The command COMPUTATION stays on the main actor (so the stateful prefix
    /// interception happens in call order), but the WRITES are paced separately
    /// through the shared outbound chain (``enqueueOutbound(_:bounded:)``): a
    /// stalled stdin pipe DEFERS input on an off-main-actor await instead of
    /// dropping a keystroke and forcing a reconnect (the prior `sendInternal`
    /// reject-on-full behavior). Prefix interception follows the server's ACTUAL
    /// prefix (`show-options -gv prefix`); a `nil` prefix byte (unbound, or a key
    /// this byte-level router can't represent) delivers everything literally
    /// rather than stealing bytes the user meant for the app.
    private func tmuxKeyCommands(paneId: Int, data: Data) -> [(command: String, kind: CommandKind)] {
        guard let prefixByte = tmuxPrefixByte else {
            return literalKeyCommands(paneId: paneId, data: data[data.startIndex...])
        }
        var commands: [(command: String, kind: CommandKind)] = []
        var index = data.startIndex

        if panesWaitingForTmuxPrefixKey.contains(paneId) {
            appendPrefixChordOrLiteral(paneId: paneId, data: data, index: &index, into: &commands)
        }

        while index < data.endIndex {
            guard data[index] == prefixByte else {
                let start = index
                repeat {
                    index = data.index(after: index)
                } while index < data.endIndex && data[index] != prefixByte
                commands.append(contentsOf: literalKeyCommands(paneId: paneId, data: data[start..<index]))
                continue
            }

            let next = data.index(after: index)
            if next == data.endIndex {
                panesWaitingForTmuxPrefixKey.insert(paneId)
                return commands
            }
            index = next
            appendPrefixChordOrLiteral(paneId: paneId, data: data, index: &index, into: &commands)
        }

        return commands
    }

    private func appendPrefixChordOrLiteral(
        paneId: Int, data: Data, index: inout Data.Index,
        into commands: inout [(command: String, kind: CommandKind)]
    ) {
        panesWaitingForTmuxPrefixKey.remove(paneId)
        guard let key = Self.tmuxClientKeyToken(in: data, at: index) else {
            var literal = Data([tmuxPrefixByte ?? Self.defaultTmuxPrefixByte])
            literal.append(data[index..<data.endIndex])
            index = data.endIndex
            commands.append(contentsOf: literalKeyCommands(paneId: paneId, data: literal[literal.startIndex...]))
            return
        }
        index = key.nextIndex
        commands.append(contentsOf: prefixChordCommands(paneId: paneId, key: key.key))
    }

    /// Max literal bytes per `send-keys -H` command line. Hex encoding triples
    /// the byte count, so this bounds each control line to ~6 KB — an unusually
    /// large typed burst (IME commit, automation) splits across a few commands
    /// instead of building one oversized line against the writer budget.
    private static let maxLiteralKeyBytesPerCommand = 2048

    private func literalKeyCommands(paneId: Int, data: Data.SubSequence) -> [(command: String, kind: CommandKind)] {
        guard !data.isEmpty else { return [] }
        var commands: [(command: String, kind: CommandKind)] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: Self.maxLiteralKeyBytesPerCommand, limitedBy: data.endIndex)
                ?? data.endIndex
            let hex = Self.hexByteArguments(data[start..<end])
            commands.append((command: "send-keys -t %\(paneId) -H \(hex)", kind: .other))
            start = end
        }
        return commands
    }

    /// The commands for one tmux prefix chord (`prefix` + `key`) targeted at
    /// `%paneId`, recording the `prefix+d` detach intent synchronously so the
    /// deferred send carries the right result kind.
    private func prefixChordCommands(paneId: Int, key: String) -> [(command: String, kind: CommandKind)] {
        let windowId = windowId(containingPane: paneId)
        let activePaneId = windowId.flatMap { activePaneByWindow[$0] }
        let isClientDetach = key == "d"
        if isClientDetach { clientDetachRequested = true }
        let kind: CommandKind = isClientDetach ? .clientDetach : .other
        return Self.tmuxClientPrefixCommands(
            paneId: paneId,
            key: key,
            activePaneId: activePaneId,
            windowId: windowId,
            prefixKeyName: tmuxPrefixKeyName ?? "C-b"
        ).map { (command: $0, kind: kind) }
    }

    nonisolated static let defaultTmuxPrefixByte: UInt8 = 0x02

    /// The server's prefix key as tracked from `show-options -gv prefix`
    /// (name for `send-keys -K`, raw control byte for typed-input interception).
    /// Defaults to C-b until the attach-time query answers; `tmuxPrefixByte`
    /// becomes `nil` for a prefix this byte router can't represent (`None`,
    /// non-Ctrl keys), which disables interception entirely.
    private(set) var tmuxPrefixKeyName: String? = "C-b"
    private var tmuxPrefixByte: UInt8? = RemoteTmuxControlConnection.defaultTmuxPrefixByte

    /// Queries the server's actual prefix key (queued right after the attach
    /// block drains, alongside the topology fetch).
    private func requestPrefixKey() {
        sendInternal("show-options -gv prefix", kind: .prefixKey)
    }

    /// Parses a `show-options -gv prefix` value. `C-a`…`C-z` map to their control
    /// byte; anything else (`None`, `F12`, `M-a`, bare printables) returns `nil`
    /// — the router only intercepts single control bytes, and guessing wrong
    /// would steal literal keys from the remote app.
    nonisolated static func parsePrefixKeyOption(_ raw: String) -> (name: String, byte: UInt8)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 3, trimmed.hasPrefix("C-"),
              let letter = trimmed.last?.lowercased().first,
              let ascii = letter.asciiValue,
              ascii >= UInt8(ascii: "a"), ascii <= UInt8(ascii: "z")
        else { return nil }
        return (trimmed, ascii - UInt8(ascii: "a") + 1)
    }

    nonisolated static func tmuxClientPrefixCommands(
        paneId: Int,
        key: String,
        activePaneId: Int?,
        windowId: Int? = nil,
        prefixKeyName: String = "C-b"
    ) -> [String] {
        // `tmux -CC` reports prefix+d as a reason-less `%exit`. Issue the
        // semantic command directly so amux can reliably treat it as an
        // explicit detach and remove the mirror workspace.
        if key == "d" { return ["detach-client"] }
        var commands: [String] = []
        // `send-keys -K` is looked up in the CONTROL CLIENT's key table against
        // the client's CURRENT window — verified against the tmux manual: with
        // `-K` the keys go to the target client, NOT the `-t` pane. With several
        // windows on one connection the client's current window may be a
        // different tab, so a bare `select-pane` (which only changes the active
        // pane WITHIN a window) would let the chord act on the wrong window's
        // active pane. Make the pane's window the client's current window first,
        // so a prefix binding acts on the focused tab's pane.
        if let windowId {
            commands.append("select-window -t @\(windowId)")
        }
        if activePaneId != paneId {
            commands.append("select-pane -t %\(paneId)")
        }
        commands.append(tmuxClientPrefixKeyCommand(key: key, prefixKeyName: prefixKeyName))
        return commands
    }

    nonisolated static func tmuxClientPrefixKeyCommand(key: String, prefixKeyName: String = "C-b") -> String {
        "send-keys -K \(RemoteTmuxHost.shellSingleQuoted(prefixKeyName)) \(RemoteTmuxHost.shellSingleQuoted(key))"
    }

    nonisolated static func tmuxClientKeyToken(in data: Data, at index: Data.Index)
        -> (key: String, nextIndex: Data.Index)?
    {
        guard index < data.endIndex else { return nil }
        let byte = data[index]
        let next = data.index(after: index)

        if byte == 0x1b {
            if let arrow = ansiCursorKeyToken(in: data, at: index) {
                return arrow
            }
            return ("Escape", next)
        }

        if byte >= 0x01 && byte <= 0x1a {
            let scalar = UnicodeScalar(UInt8(ascii: "a") + byte - 1)
            return ("C-\(Character(scalar))", next)
        }

        switch byte {
        case 0x09:
            return ("Tab", next)
        case 0x0a, 0x0d:
            return ("Enter", next)
        case 0x20:
            return ("Space", next)
        case 0x7f, 0x08:
            return ("BSpace", next)
        case 0x21...0x7e:
            return (String(Character(UnicodeScalar(byte))), next)
        default:
            return nil
        }
    }

    private nonisolated static func ansiCursorKeyToken(in data: Data, at index: Data.Index)
        -> (key: String, nextIndex: Data.Index)?
    {
        let second = data.index(after: index)
        guard second < data.endIndex else { return nil }
        let introducer = data[second]
        guard introducer == UInt8(ascii: "[") || introducer == UInt8(ascii: "O") else { return nil }
        let third = data.index(after: second)
        guard third < data.endIndex else { return nil }
        let next = data.index(after: third)
        switch data[third] {
        case UInt8(ascii: "A"): return ("Up", next)
        case UInt8(ascii: "B"): return ("Down", next)
        case UInt8(ascii: "C"): return ("Right", next)
        case UInt8(ascii: "D"): return ("Left", next)
        case UInt8(ascii: "F"): return ("End", next)
        case UInt8(ascii: "H"): return ("Home", next)
        default: return nil
        }
    }

    nonisolated static func hexByteArguments(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 3 - 1)
        for byte in data {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: " ")) }
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func windowId(containingPane paneId: Int) -> Int? {
        windowsByID.first(where: { $0.value.paneIDsInOrder.contains(paneId) })?.key
    }

    /// Pastes `text` into `paneId` as a tmux paste (`paste-buffer -p`), which wraps
    /// the content in bracketed-paste markers IFF the real pane's app has
    /// bracketed-paste mode enabled — tmux tracks that on the real pty, which the
    /// mirror surface can't see. Handles ANY text, including multi-line and large
    /// pastes: the content is octal-escaped into tmux double-quoted string chunks
    /// (`set-buffer` + `set-buffer -a`), so a newline travels as `\012` on the
    /// line-oriented control stream, and the whole paste arrives as ONE bracketed
    /// unit — a multi-line shell snippet inserts instead of executing line by
    /// line. Chunks are paced to the stdin writer's drain rate (`waitForCapacity`),
    /// so a large paste can't trip the bounded-writer rejection that the
    /// connection treats as a transport failure (which used to drop the paste AND
    /// force a reconnect). Uses a dedicated, immediately-deleted (`-d`) per-pane
    /// buffer so there's no buffer-name collision; chunks (and any typed keys)
    /// serialize on the shared ``outboundFlushTask`` so they reach tmux in order.
    /// While the transport is down the whole paste is held and replayed as one
    /// bracketed unit on reconnect (never line-by-line CRs); see the body.
    @discardableResult
    func pastePane(paneId: Int, text: String, pressEnterAfter: Bool = false) -> Bool {
        switch connectionState {
        case .ended, .connecting:
            // `.ended` will never accept it; a fresh `.connecting` stream has no
            // established session/pane to buffer into. Reject (the initial-connect
            // window is brief and not the transient-drop case B-F3 fixes).
            return false
        case .reconnecting:
            // A session that WAS connected and dropped transiently: hold the WHOLE
            // paste as ONE pending bracketed unit and flush it intact on reconnect.
            // The caller must NOT fall back to a local, line-oriented paste (which
            // replays a multi-line shell snippet line by line), so report success
            // even when the paste is too large to hold — then it is dropped cleanly
            // rather than run line by line.
            return bufferPendingPaste(paneId: paneId, text: text, pressEnterAfter: pressEnterAfter)
        case .connected:
            guard var commands = Self.pastePaneCommands(paneId: paneId, text: text) else { return false }
            // Enter must be queued INSIDE the serialized flush, after the
            // paste-buffer command — a caller-side send-keys would race ahead of
            // the (async, capacity-paced) chunk delivery and submit before the
            // pasted text exists.
            if pressEnterAfter {
                commands.append("send-keys -t %\(paneId) -H 0d")
            }
            return enqueueOutbound(commands.map { (command: $0, kind: .other) }, bounded: false)
        }
    }

    /// Serial async chain that paces BOTH typed keystrokes and chunked paste
    /// through the stdin writer's capacity. Sharing ONE chain guarantees typed
    /// sends and paste chunks reach tmux in strict enqueue order — a keystroke can
    /// never overtake a multi-chunk bracketed paste — and pacing each line via
    /// ``RemoteTmuxControlPipeWriter/waitForCapacity(_:)`` means a full stdin
    /// budget DEFERS bytes on this await instead of dropping them and reconnecting.
    private var outboundFlushTask: Task<Void, Never>?
    /// Monotonic id of the current outbound-chain tail. A completing chain task
    /// clears ``outboundFlushTask`` only when it is STILL the tail (its id still
    /// matches), which re-enables the synchronous typing fast path once the
    /// queue drains — without a stale task clobbering a newer one that was
    /// enqueued during its `await`.
    private var outboundGeneration: UInt64 = 0
    /// Outstanding bytes queued on ``outboundFlushTask`` that count against the
    /// typed-input cap (paste is user-finite and excluded). Bounds memory when
    /// typed input (key auto-repeat, automation) outruns the pipe's drain rate.
    private var pendingTypedOutboundBytes = 0
    private static let maxPendingTypedOutboundBytes = 256 * 1024

    /// Appends `commands` to the serial outbound chain, pacing each line to the
    /// stdin writer's capacity. `bounded` charges the bytes against the typed-input
    /// cap and rejects (returns `false`) if that would overflow, so a runaway typed
    /// flood can't grow memory without limit; paste passes `false` (finite,
    /// user-initiated). Returns `false` when the connection isn't live, or when the
    /// bounded cap is hit. Ordering + FIFO correlation are preserved because each
    /// command's ``sendInternal`` (which records its pending-command slot then
    /// enqueues, atomically on the main actor) still runs in append order.
    @discardableResult
    private func enqueueOutbound(
        _ commands: [(command: String, kind: CommandKind)],
        bounded: Bool
    ) -> Bool {
        guard connectionState == .connected, stdinWriter != nil else { return false }
        let payload = commands.filter { !$0.command.isEmpty }
        guard !payload.isEmpty else { return true }
        let byteCount = payload.reduce(0) { $0 + $1.command.utf8.count + 1 }
        if bounded {
            guard pendingTypedOutboundBytes + byteCount <= Self.maxPendingTypedOutboundBytes else { return false }
            pendingTypedOutboundBytes += byteCount
        }
        let previous = outboundFlushTask
        outboundGeneration &+= 1
        let generation = outboundGeneration
        outboundFlushTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if bounded {
                    self.pendingTypedOutboundBytes = max(0, self.pendingTypedOutboundBytes - byteCount)
                }
                // Re-enable the sync fast path once the chain drains: clear the
                // tail only if no newer send superseded us during our await. Our
                // last sendInternal has already enqueued to the serial writer, so
                // a following fast-path send still lands after it on the wire.
                if self.outboundGeneration == generation {
                    self.outboundFlushTask = nil
                }
            }
            for entry in payload {
                guard !Task.isCancelled, self.connectionState == .connected,
                      let writer = self.stdinWriter else { return }
                guard await writer.waitForCapacity(entry.command.utf8.count + 1) else { return }
                guard !Task.isCancelled, self.connectionState == .connected else { return }
                guard self.sendInternal(entry.command, kind: entry.kind) else { return }
            }
        }
        return true
    }

    /// Paste text held while the transport is down, flushed as intact bracketed
    /// units on reconnect (see ``pastePane(paneId:text:pressEnterAfter:)``).
    /// Bounded by ``pendingPasteBytes`` so a blip can't accumulate unbounded memory.
    private var pendingPasteByPane: [Int: [(text: String, pressEnterAfter: Bool)]] = [:]
    private var pendingPasteBytes = 0
    private static let maxPendingPasteBytes = 256 * 1024

    private func bufferPendingPaste(paneId: Int, text: String, pressEnterAfter: Bool) -> Bool {
        guard !text.isEmpty else { return false }
        let cost = text.utf8.count
        // Too large to hold: reject cleanly (still report success) so the caller
        // doesn't paste it locally line by line; dropping a single oversized paste
        // typed during a transient blip is acceptable.
        guard pendingPasteBytes + cost <= Self.maxPendingPasteBytes else { return true }
        pendingPasteBytes += cost
        pendingPasteByPane[paneId, default: []].append((text: text, pressEnterAfter: pressEnterAfter))
        return true
    }

    /// Replays paste buffered during a transport outage as intact bracketed units
    /// once the stream is back in control mode (called from the `.enter` handler
    /// after `flushPendingInput`, so typed keys from the same blip land first).
    private func flushPendingPaste() {
        guard !pendingPasteByPane.isEmpty else { return }
        let pending = pendingPasteByPane
        pendingPasteByPane.removeAll()
        pendingPasteBytes = 0
        for (paneId, pastes) in pending.sorted(by: { $0.key < $1.key }) {
            for paste in pastes {
                _ = pastePane(paneId: paneId, text: paste.text, pressEnterAfter: paste.pressEnterAfter)
            }
        }
    }

    /// Max escaped bytes per `set-buffer` chunk. Keeps each control-stream line
    /// comfortably bounded; worst-case escape expansion is 4× (every byte `\ooo`).
    nonisolated static let pasteChunkMaxEscapedBytes = 4096

    /// The full command sequence that delivers `text` to `paneId` as a bracketed
    /// tmux paste: one or more `set-buffer` chunk lines followed by the final
    /// `paste-buffer -p -d`. `nil` for empty text.
    nonisolated static func pastePaneCommands(
        paneId: Int,
        text: String,
        maxEscapedChunkBytes: Int = pasteChunkMaxEscapedBytes
    ) -> [String]? {
        guard !text.isEmpty else { return nil }
        let buffer = "cmux-paste-\(paneId)"
        var commands: [String] = []
        var chunk = [UInt8]()
        chunk.reserveCapacity(min(maxEscapedChunkBytes + 4, text.utf8.count * 4))
        func flush() {
            guard !chunk.isEmpty else { return }
            let flag = commands.isEmpty ? "-b" : "-ab"
            commands.append("set-buffer \(flag) \(buffer) -- \"\(String(decoding: chunk, as: UTF8.self))\"")
            chunk.removeAll(keepingCapacity: true)
        }
        for byte in text.utf8 {
            appendTmuxDoubleQuotedEscaped(byte, to: &chunk)
            if chunk.count >= maxEscapedChunkBytes { flush() }
        }
        flush()
        commands.append("paste-buffer -p -d -b \(buffer) -t %\(paneId)")
        return commands
    }

    /// Appends `byte` to `out` in tmux double-quoted-string form. Alphanumerics
    /// and a small punctuation set pass through; EVERYTHING else — including
    /// `"`, `\`, `$` (env expansion), `#` (format/comment), `;` (command
    /// separator), newlines, other control bytes, and non-ASCII — becomes a
    /// 3-digit octal escape (`\012`), which tmux's own command parser decodes
    /// back to the raw byte (verified against tmux 3.7b). Escaping into tmux's
    /// grammar (not `/bin/sh`'s) is the point: these lines feed tmux's parser
    /// directly, never a shell.
    nonisolated private static func appendTmuxDoubleQuotedEscaped(_ byte: UInt8, to out: inout [UInt8]) {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: " "), UInt8(ascii: "."), UInt8(ascii: ","),
             UInt8(ascii: "/"), UInt8(ascii: "_"), UInt8(ascii: "-"),
             UInt8(ascii: ":"), UInt8(ascii: "="), UInt8(ascii: "+"),
             UInt8(ascii: "@"):
            out.append(byte)
        default:
            out.append(UInt8(ascii: "\\"))
            out.append(UInt8(ascii: "0") + (byte >> 6))
            out.append(UInt8(ascii: "0") + ((byte >> 3) & 0x7))
            out.append(UInt8(ascii: "0") + (byte & 0x7))
        }
    }

    /// Safety net for a connection released without an explicit ``stop()`` (e.g.
    /// an owner dropped mid-flight). Best-effort terminates the current spawn's
    /// child so a live `tmux -CC` / ssh control client is never orphaned.
    ///
    /// `deinit` is nonisolated, so this touches only the captured `Process`
    /// directly (Swift guarantees exclusive access at deinit) and never hops to a
    /// `@MainActor` method such as ``teardownProcessHandles()``. The normal
    /// teardown paths (``stop()``, `%exit`, reconnect) already terminate and clear
    /// `process`, so this fires only when none of them ran.
    deinit {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    /// Detaches: terminating ssh kills the control client but leaves the remote
    /// tmux session alive for resume. Permanently ends the connection — no reconnect.
    func stop() {
        // Mark `.ended` FIRST so the deliberate teardown's stream-end is ignored and
        // never fires `onExit` or a reconnect: only a genuine remote end (a real
        // `%exit` or a session found gone on reconnect) notifies exit observers — so
        // detach / quit / window-close (preserve) and transport drops do not.
        connectionState = .ended
        cancelScheduledWork()
        teardownProcessHandles()
    }

    /// Cancels every scheduled follow-up (reconnect, debounced size send, redraw
    /// kick) and the deferred post-attach work. Shared by deliberate teardown
    /// (``stop()``) and a genuine remote end (`%exit`).
    private func cancelScheduledWork() {
        failPendingActivityQueries()
        reconnectTask?.cancel()
        reconnectTask = nil
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = nil
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = nil
        outboundFlushTask?.cancel()
        outboundFlushTask = nil
        pendingTypedOutboundBytes = 0
        pendingInputByPane.removeAll()
        pendingPasteByPane.removeAll()
        pendingPasteBytes = 0
        // Drop any dangling prefix-wait so a half-typed `prefix` can't consume the
        // next unrelated key/socket send after teardown. (`clientDetachRequested`
        // is intentionally left alone: the `%exit` path reads it right after this
        // to classify a `prefix+d` detach.)
        panesWaitingForTmuxPrefixKey.removeAll()
        pendingAttachRedrawKick = false
        pendingPostAttachAction = nil
    }

    /// Tears down the current spawn's process and I/O handles WITHOUT changing
    /// `connectionState`, so the connection can either end (``stop()``) or re-spawn
    /// (reconnect) from a clean slate.
    private func teardownProcessHandles() {
        ingestTask?.cancel()
        ingestTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminationHandler = nil
        // Tear down the readers deterministically rather than waiting for EOF (the
        // consumers are already cancelled).
        stderrReader?.readabilityHandler = nil
        stderrReader = nil
        stdoutPipeReader?.close()
        stdoutPipeReader = nil
        stdoutReader = nil
        stderrContinuation?.finish()
        stderrContinuation = nil
        stdinWriter?.close()
        stdinWriter = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Internals

    @discardableResult
    private func sendInternal(_ command: String, kind: CommandKind) -> Bool {
        guard connectionState == .connected, let stdinWriter else { return false }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        guard let data = line.data(using: .utf8) else { return false }
        // Record before the writer can emit bytes, so a fast `%begin`/`%end`
        // reply never outruns its local FIFO slot. If the bounded writer rejects
        // the command, remove this slot immediately and reconnect.
        pendingCommands.append(kind)
        guard stdinWriter.enqueue(data) else {
            pendingCommands.removeLast()
            record("stdin-write-backpressure")
            beginReconnecting()
            return false
        }
        return true
    }

    private func handleStdinWriteFailure() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        // The control pipe is dead (broken pipe or a closed SSH child). Keep the
        // mirror frozen and reconnect; teardown finishes the old streams so
        // pending command correlation cannot consume replies from a dead client.
        record("stdin-write-failed")
        beginReconnecting()
    }

    private func handleStdoutBackpressureOverflow() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        // The parser fell far enough behind the SSH pipe that preserving every
        // control-mode byte would exceed the bridge budget. Reconnect instead of
        // dropping bytes and desynchronizing command/result parsing.
        record("stdout-backpressure")
        beginReconnecting()
    }

    /// Applies a batch of parsed control messages on the main actor (the
    /// off-main ingest task awaits each batch, preserving stream order).
    private func deliver(_ messages: [RemoteTmuxControlMessage]) {
        for message in messages {
            handle(message)
        }
    }

    private func handleStreamEnd() async {
        record("stream-end")
        switch connectionState {
        case .ended:
            return
        case .connecting, .connected:
            // The control stream died without `%exit` — a transport loss. Keep the
            // mirror frozen and reconnect.
            beginReconnecting()
        case .reconnecting:
            // A reconnect attempt's process exited before reaching control mode
            // (a successful attach would have moved us to `.connected` via `.enter`).
            // Drain the attempt's stderr to completion (the process has exited, so the
            // stream finishes) BEFORE classifying, so the decision can't race a
            // not-yet-delivered chunk and misclassify a gone session as transient.
            await stderrTask?.value
            // A state change may have raced the drain (e.g. a deliberate stop()).
            guard connectionState == .reconnecting else { return }
            // Classify: a session/server found gone is a genuine end; anything else
            // (host unreachable, refused) is transient — keep retrying with backoff.
            let sessionGone = decoding.stderrIndicatesSessionGone(stderrBuffer)
            teardownProcessHandles()
            if sessionGone {
                record("reconnect-session-gone")
                connectionState = .ended
                reconnectTask?.cancel()
                reconnectTask = nil
                observers.notifyExit()
            } else {
                scheduleReconnectAttempt()
            }
        }
    }

    // MARK: - Reconnect

    /// Begins reconnecting after a transport loss: tears down the dead spawn, marks
    /// `.reconnecting` (consumers keep the frozen mirror), and schedules the first
    /// retry. No-op unless currently connected/connecting.
    private func beginReconnecting() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        record("reconnecting")
        // The stream is dead: a close decision awaiting an activity query must
        // not hang for the whole backoff window — fail it onto the cache now.
        failPendingActivityQueries()
        // Abandon in-flight paced sends and dangling key state: the pipe is gone,
        // so a half-typed `prefix` or an unsent `prefix+d` detach intent must not
        // leak into the resumed session (typed/paste from the outage are held in
        // pendingInputByPane / pendingPasteByPane and replayed on `%enter`).
        outboundFlushTask?.cancel()
        outboundFlushTask = nil
        pendingTypedOutboundBytes = 0
        panesWaitingForTmuxPrefixKey.removeAll()
        clientDetachRequested = false
        teardownProcessHandles()
        reconnectAttemptCount = 0
        connectionState = .reconnecting
        scheduleReconnectAttempt()
    }

    /// Schedules the next reconnect attempt after a capped exponential backoff.
    private func scheduleReconnectAttempt() {
        let attempt = reconnectAttemptCount
        reconnectAttemptCount += 1
        // ±20% jitter: with several mirrors offline at once (laptop wake, VPN
        // drop) an unjittered backoff settles every connection at the 10s cap in
        // lockstep — a periodic thundering herd of ssh spawns.
        let delay = min(
            Self.reconnectMaxDelaySeconds,
            Self.reconnectBaseDelaySeconds * pow(2, Double(attempt))
        ) * Double.random(in: 0.8...1.2)
        record("reconnect-scheduled attempt=\(attempt) delay=\(delay)")
        reconnectTask?.cancel()
        // A bounded, cancellable backoff before the next attempt (not a poll/settle):
        // cancelled by stop()/genuine end, re-armed by each failed attempt. `do/catch`
        // (not `try?`) so a cancelled sleep returns immediately — the previously
        // scheduled task can't fall through and double-spawn a second ssh client.
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.connectionState == .reconnecting else { return }
            self.attemptReconnectSpawn()
        }
    }

    /// Re-spawns the ssh control client for a reconnect attempt. Always attach-only
    /// (`createIfMissing: false`) so a session killed during the outage fails the
    /// re-attach (→ classified `.ended`) instead of being silently recreated empty.
    /// A spawn failure (e.g. control-socket dir) backs off and retries; the spawn's
    /// success/failure is observed via `.enter` (connected) or `handleStreamEnd`.
    private func attemptReconnectSpawn() {
        record("reconnect-attempt")
        do {
            try spawnProcess(createIfMissing: false)
        } catch {
            scheduleReconnectAttempt()
        }
    }

    /// Re-seeds every mirrored pane after a successful reconnect: the fresh ssh
    /// client lost the prior screen, cwd subscriptions, and client size, so re-apply
    /// the grid, then per pane clear the stale frozen content (screen + scrollback)
    /// and re-capture current contents (with history) + cwd. Called from the first
    /// post-reconnect `list-windows` result, so `windowsByID` is freshly repopulated
    /// and the command-result FIFO is aligned (the attach block is already drained).
    private func reseedAfterReconnect() {
        if let size = lastClientSize {
            send("refresh-client -C \(size.columns)x\(size.rows)")
        }
        // The re-applied size is usually a no-op (the server kept the window at our
        // size across the transport drop), so TUIs get no SIGWINCH — kick them so
        // they repaint over the re-seeded (possibly stale) frame. FIFO-safe: the
        // captures below are queued before the kick task's first push can run.
        scheduleAttachRedrawKickIfNeeded()
        for window in windowsByID.values {
            for paneId in window.paneIDsInOrder {
                // `ESC[m` first so the full clear erases with the default background
                // (not a stale SGR pen left from before the transport drop).
                observers.emitPaneOutput(paneId, Data("\u{1b}[m\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8))
                seedPane(paneId: paneId)
            }
        }
    }

    private func handle(_ message: RemoteTmuxControlMessage) {
        switch message {
        case .enter:
            enterReceived = true
            record("enter")
            // First connect, or a reconnect attempt that reached control mode.
            if connectionState != .connected {
                let wasReconnecting = connectionState == .reconnecting
                connectionState = .connected
                // Arm the one-shot attach redraw kick: if the upcoming size apply is
                // a no-op (window already at our size), a running TUI gets no SIGWINCH
                // and would keep showing its stale pre-attach frame. Consumed by the
                // first size apply (debounced send, reconnect re-seed, or the
                // first-connect list-windows result).
                pendingAttachRedrawKick = true
                reconnectAttemptCount = 0
                reconnectTask?.cancel()
                reconnectTask = nil
                // Do not send here: `.enter` precedes the attach result block, so a
                // command queued now could be consumed by that result and shift the
                // FIFO. The attach-block drain queues list-windows once alignment is safe.
                pendingPostAttachAction = wasReconnecting ? .reseed : .applyClientSize
                // Input typed during the outage, though, replays immediately: its
                // replies correlate positionally like any queued command, and the
                // sooner it reaches the pty the closer we match a real ssh
                // session's behavior across a blip. Paste held during the outage
                // flushes AFTER typed input so a type-then-paste from the same blip
                // keeps its order, and replays as ONE bracketed unit (never the
                // line-by-line CR replay that would run a shell snippet line by line).
                flushPendingInput()
                flushPendingPaste()
            }
        case let .exit(reason):
            record("exit\(reason.map { " " + $0 } ?? "")")
            // A genuine remote end (session/server intentionally exited). No reconnect.
            guard connectionState != .ended else { return }
            connectionState = .ended
            cancelScheduledWork()
            // Reap this spawn's process and I/O handles too — `%exit` means the
            // control client is finished, so leaving the child/handles around
            // (as this case previously did) needlessly held them until dealloc.
            // `teardownProcessHandles()` leaves `connectionState` untouched, so it
            // is safe to call here after the `.ended` transition above.
            teardownProcessHandles()
            observers.notifyExit()
        case let .output(paneId, data):
            paneOutputByteCounts[paneId, default: 0] += data.count
            totalOutputBytes += data.count
            observers.emitPaneOutput(paneId, data)
        case let .sessionChanged(id, name):
            // An attached-session SWITCH: the window set changes with it, so
            // re-fetch the topology.
            applySessionNameChange(sessionId: id, name: name, event: "session-changed", refetchWindows: true)
        case let .sessionRenamed(id, name, idBearingName):
            // tmux's `rename-session` notification. Same name handling as
            // `%session-changed` (track the new name for attach/reconnect and emit
            // the name-change observers that re-key controller state and re-title
            // the mirror workspace), but a rename does NOT change the window set,
            // so skip the topology re-fetch.
            guard let renameName = sessionRenamedName(
                sessionId: id,
                documentedName: name,
                idBearingName: idBearingName
            ) else { return }
            applySessionNameChange(sessionId: id, name: renameName, event: "session-renamed", refetchWindows: false)
        case .sessionsChanged:
            record("sessions-changed")
        case let .windowAdd(id):
            record("window-add @\(id)")
            requestWindows()
        case let .windowClose(id):
            // Release the closed window's per-pane/per-window diagnostic state so
            // it doesn't accumulate across window churn.
            if let closing = windowsByID[id] {
                for pane in closing.paneIDsInOrder {
                    paneOutputByteCounts[pane] = nil
                    paneForegroundStates[pane] = nil
                }
            }
            activePaneByWindow[id] = nil
            windowsByID[id] = nil
            windowOrder.removeAll { $0 == id }
            record("window-close @\(id)")
            observers.notifyTopologyChanged()
        case let .windowRenamed(id, name):
            record("window-renamed @\(id)")
            // Propagate the new name into the topology so the mirrored tab title
            // refreshes. Keep the existing geometry/layout.
            if let existing = windowsByID[id], existing.name != name {
                windowsByID[id] = RemoteTmuxWindow(
                    id: id, name: name,
                    width: existing.width, height: existing.height, layout: existing.layout,
                    visibleLayout: existing.visibleLayout
                )
                observers.notifyTopologyChanged()
            }
        case let .layoutChange(id, layout, visibleLayout, zoomed):
            applyLayout(windowId: id, layout: layout, visibleLayout: visibleLayout, zoomed: zoomed)
            record("layout-change @\(id)\(zoomed ? " zoomed" : "")")
            observers.notifyTopologyChanged()
        case let .windowPaneChanged(windowId, paneId):
            activePaneByWindow[windowId] = paneId
            observers.emitActivePaneChanged(windowId, paneId)
        case let .sessionWindowChanged(_, windowId):
            record("session-window-changed @\(windowId)")
        case let .subscriptionChanged(name, value):
            // cmux subscribes each pane's working directory as "cmux_cwd_<paneId>".
            if name.hasPrefix(Self.cwdSubscriptionPrefix),
               let paneId = Int(name.dropFirst(Self.cwdSubscriptionPrefix.count)) {
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { observers.emitPaneCwd(paneId, path) }
            } else if name.hasPrefix(Self.reflowSubscriptionPrefix),
                      let paneId = Int(name.dropFirst(Self.reflowSubscriptionPrefix.count)) {
                // Reflow classification: "<alternate_on>|<pane_current_command>".
                classifyAndEmitReflow(paneId: paneId, rawValue: value, source: "sub")
            }
        case let .commandResult(_, lines, isError):
            // The first block on each control stream is the attach command's own —
            // consume it explicitly so it can never pop a queued command's slot off
            // the positional FIFO (see ``attachBlockDrained``).
            if !attachBlockDrained {
                attachBlockDrained = true
                requestWindows()
                requestPrefixKey()
            } else {
                handleCommandResult(lines: lines, isError: isError)
            }
        case let .streamError(reason):
            record("stream-error \(reason)")
            beginReconnecting()
        case .ignoredNotification, .unparsed:
            break
        }
    }

    /// Shared handling for `%session-changed` and `%session-renamed`: validate the
    /// name, update the tracked display name and stable attach target, then emit
    /// the observers that re-key controller state and re-title the workspace.
    ///
    /// - Parameter refetchWindows: re-fetch the window topology afterwards. A
    ///   session SWITCH (`%session-changed`) brings a different window set, so it
    ///   must; a rename (`%session-renamed`) keeps the same windows, so it skips
    ///   the extra round trip. An invalid name always re-fetches as a recovery
    ///   resync regardless.
    private func applySessionNameChange(sessionId newSessionId: Int?, name: String, event: String, refetchWindows: Bool) {
        guard let safeName = RemoteTmuxHost.controlModeLineSafeName(name) else {
            let idSuffix = newSessionId.map { " $\($0)" } ?? ""
            record("\(event)-invalid\(idSuffix)")
            requestWindows()
            return
        }
        let oldName = sessionName
        if let newSessionId {
            sessionId = newSessionId
            attachTarget = "$\(newSessionId)"
        } else if sessionId == nil {
            attachTarget = safeName
        }
        sessionName = safeName
        let idSuffix = newSessionId.map { " $\($0)" } ?? ""
        record("\(event)\(idSuffix)")
        observers.emitSessionChanged(oldName: oldName, newName: safeName)
        if refetchWindows { requestWindows() }
    }

    private func sessionRenamedName(sessionId renamedSessionId: Int?, documentedName: String, idBearingName: String?) -> String? {
        guard let renamedSessionId else { return documentedName }
        // Real tmux id-bearing renames are broadcast for every session; only this
        // connection's id may use the id-bearing interpretation.
        guard let currentSessionId = sessionId, currentSessionId == renamedSessionId else {
            record("session-renamed-ignored $\(renamedSessionId)")
            return nil
        }
        return idBearingName ?? documentedName
    }

    private func handleCommandResult(lines: [String], isError: Bool) {
        // The attach block was already consumed upstream (`attachBlockDrained`);
        // an empty FIFO here means an unsolicited block — drop it rather than
        // misalign the positional correlation.
        guard !pendingCommands.isEmpty else { return }
        let kind = pendingCommands.removeFirst()
        guard !isError else {
            if kind == .clientDetach { clientDetachRequested = false }
            // An errored activity query must still complete (with nil) — a close
            // decision is waiting on it and falls back to the cached state.
            if case let .activityQuery(token) = kind,
               let completion = activityQueryCompletions.removeValue(forKey: token) {
                completion(nil)
            }
            // Errors are dropped by design (results correlate positionally), but
            // an invisible %error has already hidden one real bug — an unquoted
            // refresh-client -B that never subscribed — so leave a trace.
            #if DEBUG
            cmuxDebugLog(
                "remote.tmux.commandError kind=\(kind) error=\"\(lines.joined(separator: " / "))\""
            )
            #endif
            return
        }
        switch kind {
        case .listWindows:
            var order: [Int] = []
            var next: [Int: RemoteTmuxWindow] = [:]
            var initialActivePane: [Int: Int] = [:]
            for line in lines {
                // "@<id> %<active-pane> <Z|-> <layout> <visible-layout>
                // <name with spaces…>" — every field before the name never
                // contains spaces, so split into at most 6 fields.
                let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
                guard parts.count >= 5,
                      let id = RemoteTmuxControlStreamParser.id(parts[0], sigil: "@"),
                      let activePane = RemoteTmuxControlStreamParser.id(parts[1], sigil: "%"),
                      let node = RemoteTmuxRawLayoutParser.parse(String(parts[3]))
                else { continue }
                let zoomed = parts[2] == "Z"
                let visibleNode = zoomed ? RemoteTmuxRawLayoutParser.parse(String(parts[4])) : nil
                let name = parts.count >= 6 ? String(parts[5]) : ""
                next[id] = RemoteTmuxWindow(
                    id: id, name: name, width: node.width, height: node.height, layout: node,
                    visibleLayout: visibleNode
                )
                initialActivePane[id] = activePane
                order.append(id)
            }
            // Ignore an empty/garbled reply on purpose: a live tmux session always
            // has ≥1 window, so a zero-window parse is a transient or malformed
            // result, not a real topology. Acting on it would wipe `windowOrder`
            // and tear down every mirror tab. A genuine "no windows" state means
            // the session ended — that arrives as the connection's `%exit` /
            // stream-end (see `handleConnectionExited` → `handleSessionEndedRemotely`),
            // which is the path that closes the workspace / dedicated window.
            if !order.isEmpty {
                // Replace topology instead of merging: a remote close missed while
                // disconnected leaves no %window-close, so prune stale panes here.
                let liveIDs = Set(order)
                windowsByID = next
                // Event-driven entries win over the list snapshot (a
                // %window-pane-changed may have arrived since this reply was
                // generated); the snapshot only seeds windows with no entry.
                activePaneByWindow = initialActivePane.merging(
                    activePaneByWindow.filter { liveIDs.contains($0.key) },
                    uniquingKeysWith: { _, eventDriven in eventDriven }
                )
                prunePaneState(keeping: Set(next.values.flatMap { $0.paneIDsInOrder }))
                windowOrder = order
                observers.notifyTopologyChanged()
                // The attach block is drained and the topology is fresh — run the
                // deferred post-attach work; commands queued here correlate cleanly
                // (see ``PostAttachAction``).
                switch pendingPostAttachAction {
                case .reseed:
                    reseedAfterReconnect()
                case .applyClientSize:
                    // A surface that hasn't computed a grid yet is covered by the
                    // debounced `setClientSize` instead.
                    if let size = lastClientSize {
                        send("refresh-client -C \(size.columns)x\(size.rows)")
                    }
                case nil:
                    break
                }
                pendingPostAttachAction = nil
                // First-connect coverage for the attach redraw kick: if the grid was
                // computed before `.enter`, no post-connect `setClientSize` may ever
                // fire (layout settled + same-size dedupe upstream), so the
                // debounced-send consumer never runs. This is the earliest point with
                // populated topology — and `windowsByID` was parsed from THIS
                // list-windows reply, generated before tmux processed the size apply
                // just queued above, so the at-target check sees the true pre-apply
                // geometry. No-op when the kick was already consumed (or when
                // reseedAfterReconnect just ran it).
                scheduleAttachRedrawKickIfNeeded()
            }
        case let .capturePane(paneId):
            // capture-pane -e -S output is the pane's history + visible rows (with
            // SGR escapes). Home + clear the VISIBLE SCREEN (ESC[2J — NOT ESC[3J,
            // which would erase the scrollback we are seeding), then write every
            // captured row joined by CR LF: rows that overflow the screen scroll up
            // into the surface's scrollback buffer, which is what makes the mirrored
            // tab scrollable from the start. The last row (the visible bottom) gets
            // no trailing newline so the cursor lands at its END, lining up with
            // tmux's real prompt cursor — otherwise echoed input lands a line below
            // the prompt. The `.paneState` seed then repositions the cursor within
            // the visible screen.
            // `ESC[m` first: the erase fills with the CURRENT SGR background, and a
            // surface reused across reconnect (or one an alt-screen app left with a
            // colored pen) would otherwise flash — or keep — that stale background.
            let painted = "\u{1b}[m\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n")
            if let data = painted.data(using: .utf8) {
                observers.emitPaneOutput(paneId, data)
            }
        case let .paneState(paneId):
            // Restore the pane's terminal state (scroll region + DEC modes + cursor)
            // onto the mirror surface, applied after the capture paint. The scroll
            // region (DECSTBM) is the important one: without it an inline TUI's
            // region-relative redraws land on the wrong rows even at a static size.
            if let line = lines.first {
                observers.emitPaneOutput(paneId, decoding.paneStateSeedSequence(from: line))
            }
        case let .panePath(paneId):
            if let path = lines.first?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                observers.emitPaneCwd(paneId, path)
            }
        case let .paneReflow(paneId):
            // One-shot reflow classification result (see requestPaneReflow). Empty
            // lines → classifyAndEmitReflow defaults to no-reflow (safe).
            classifyAndEmitReflow(paneId: paneId, rawValue: lines.first ?? "", source: "oneshot")
        case let .activityQuery(token):
            guard let completion = activityQueryCompletions.removeValue(forKey: token) else { break }
            var states: [Int: PaneForegroundState] = [:]
            for line in lines {
                guard let parsed = Self.parseActivityQueryLine(line) else { continue }
                states[parsed.paneId] = parsed.state
            }
            // The fresh answer flows back into the cache, so the synchronous
            // consumers (batch close, workspace close, quit warning) benefit too.
            for (paneId, state) in states { paneForegroundStates[paneId] = state }
            completion(states)
        case .prefixKey:
            // The server's actual prefix. An unparseable value (a remapped
            // non-Ctrl prefix, `None`) disables typed-input interception rather
            // than falling back to C-b — stealing literal bytes is worse than
            // asking the user to drive tmux bindings from a real client.
            let parsed = Self.parsePrefixKeyOption(lines.first ?? "")
            tmuxPrefixKeyName = parsed?.name
            tmuxPrefixByte = parsed?.byte
            #if DEBUG
            cmuxDebugLog("remote.tmux.prefix key=\(parsed?.name ?? "disabled")")
            #endif
        case let .paneAltScreen(paneId):
            // Match the mirror surface to the remote pane's screen (alt = no reflow on
            // resize). Emitted before the capture paint that follows in the FIFO, so the
            // seeded rows land on the right screen. The else branch is load-bearing on a
            // surface REUSED across reconnect: if it was on the alt screen before and the
            // remote pane is now on primary, force it back (1049l) so the capture doesn't
            // paint onto a stale alt screen.
            if lines.first?.trimmingCharacters(in: .whitespaces) == "1" {
                observers.emitPaneOutput(paneId, Self.altScreenEnterSequence)
            } else {
                observers.emitPaneOutput(paneId, Self.altScreenExitSequence)
            }
        case .clientDetach, .other:
            break
        }
    }

    private func applyLayout(windowId: Int, layout: String, visibleLayout: String?, zoomed: Bool) {
        guard let node = RemoteTmuxRawLayoutParser.parse(layout) else { return }
        // Only a ZOOMED window renders its visible layout; unzoomed the two are
        // identical and carrying nil keeps `RemoteTmuxWindow.zoomed` meaningful.
        let visibleNode = zoomed ? visibleLayout.flatMap { RemoteTmuxRawLayoutParser.parse($0) } : nil
        // Preserve any name tmux already reported (a %layout-change carries no name).
        let existingName = windowsByID[windowId]?.name ?? ""
        windowsByID[windowId] = RemoteTmuxWindow(
            id: windowId, name: existingName, width: node.width, height: node.height, layout: node,
            visibleLayout: visibleNode
        )
        if !windowOrder.contains(windowId) { windowOrder.append(windowId) }
        prunePaneState(keeping: Set(windowsByID.values.flatMap { $0.paneIDsInOrder }))
    }

    private func prunePaneState(keeping livePanes: Set<Int>) {
        paneOutputByteCounts = paneOutputByteCounts.filter { livePanes.contains($0.key) }
        paneForegroundStates = paneForegroundStates.filter { livePanes.contains($0.key) }
    }

    private func record(_ event: String) {
        diagnostics.record(event)
    }

    /// An immutable, `Sendable` snapshot for diagnostics (`remote.tmux.state`).
    func snapshot() -> Snapshot {
        Snapshot(
            started: started,
            enterReceived: enterReceived,
            exited: exited,
            sessionId: sessionId,
            windowCount: windowsByID.count,
            windowIDs: windowOrder,
            paneOutputByteCounts: paneOutputByteCounts,
            totalOutputBytes: totalOutputBytes,
            recentEvents: diagnostics.events
        )
    }

    #if DEBUG
    func installStdinWriterForTesting(_ writer: RemoteTmuxControlPipeWriter) { stdinWriter = writer }
    func handleMessageForTesting(_ message: RemoteTmuxControlMessage) { handle(message) }
    func handleClientDetachExitForTesting() {
        clientDetachRequested = true
        handle(.exit(reason: nil))
    }
    var pendingCommandKindsForTesting: [RemoteTmuxControlCommandKind] { pendingCommands }
    #endif

}
