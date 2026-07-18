import CmuxMuxa
import CmuxSidebar
import Foundation

/// Streams muxad agent state into mirrored workspaces' sidebar status rows.
///
/// muxad (muxa's daemon) correlates Claude Code / Codex / Gemini hook events
/// with tmux panes and sessions. This service joins those agent rows to amux
/// local-engine mirror workspaces by tmux session name and writes one keyed
/// ``SidebarStatusEntry`` per workspace summarizing its agents (working /
/// waiting / error counts). A missing daemon degrades silently: the loop
/// retries on a long interval and no entries are written.
@MainActor
final class AmuxAgentStatusService {
    /// The `statusEntries` key this service owns on each workspace.
    static let statusEntryKey = "amux.agents"

    private let client: MuxaClient
    /// Resolves the workspace mirroring a tmux session name (injected so
    /// tests can drive the service without a RemoteTmuxController).
    private let workspaceForSession: @MainActor (String) -> Workspace?
    /// Resolves the workspace whose mirrored session contains a tmux pane —
    /// the fallback join while muxad rows carry no session name (v3 dropped
    /// `tmux_session` from the wire).
    private let workspaceForPane: @MainActor (Int) -> Workspace?
    /// Runs before every connect attempt — the remote-host seam where the
    /// hub re-establishes the SSH socket forward. `nil` for the local daemon.
    private let prepareConnection: (@Sendable () async throws -> Void)?
    /// Receives every live state transition together with the workspace it
    /// resolved to (`nil` when the agent isn't in a mirrored session) — the
    /// alarm/notification seam. Snapshot rows never fire this.
    private let onTransition: (@MainActor (MuxaTransition, Workspace?) -> Void)?
    /// Receives the session ids that VANISHED between the previous successful
    /// snapshot and the latest one — the seam the composition root uses to
    /// forget per-session memory that outlives its agent (e.g.
    /// ``AmuxAgentAlarmGate/forget(sessionIds:)`` for agents that went away
    /// while blocked, with no `stopped` transition). It passes only this
    /// daemon's departed delta — never this daemon's live set — because the
    /// shared alarm gate must not evict another daemon's still-live episodes.
    /// The service's own ``agentsBySessionId`` is pruned by the wholesale
    /// snapshot replacement below; this is purely for shared state it doesn't own.
    private let onSessionsVanished: (@MainActor (Set<String>) -> Void)?
    /// Live agent rows by muxad session id (agent-CLI session, not tmux).
    private var agentsBySessionId: [String: MuxaAgent] = [:]
    /// Session ids from the previous successful snapshot, so the next snapshot
    /// can report the vanished delta to ``onSessionsVanished``. Persists across
    /// a stream drop/reconnect (a disconnect is not a vanish), so a still-blocked
    /// agent's gate episode survives and its reconnect tick isn't re-alarmed.
    private var lastSnapshotSessionIds: Set<String> = []
    /// Weakly holds a workspace we wrote a row into.
    private struct WeakWorkspace {
        weak var value: Workspace?
    }

    /// Workspaces currently carrying our status entry (held weakly), so a
    /// workspace whose agents all left gets its row cleared.
    private var workspacesWithEntry: [UUID: WeakWorkspace] = [:]
    private var streamTask: Task<Void, Never>?

    init(
        client: MuxaClient = MuxaClient(),
        workspaceForSession: @escaping @MainActor (String) -> Workspace?,
        workspaceForPane: @escaping @MainActor (Int) -> Workspace?,
        prepareConnection: (@Sendable () async throws -> Void)? = nil,
        onTransition: (@MainActor (MuxaTransition, Workspace?) -> Void)? = nil,
        onSessionsVanished: (@MainActor (Set<String>) -> Void)? = nil
    ) {
        self.client = client
        self.workspaceForSession = workspaceForSession
        self.workspaceForPane = workspaceForPane
        self.prepareConnection = prepareConnection
        self.onTransition = onTransition
        self.onSessionsVanished = onSessionsVanished
    }

    /// Starts the snapshot+subscribe loop (idempotent).
    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.run()
        }
        // Freshness tick: a `working` badge whose agent went silent (missed
        // hook, crashed CLI) would otherwise show "working" forever — there is
        // no transition to re-render on. Re-projecting once a minute lets
        // ``statusEntry(for:now:)``'s staleness decay demote it.
        freshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.applyToWorkspaces()
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        freshnessTask?.cancel()
        freshnessTask = nil
    }

    private var freshnessTask: Task<Void, Never>?

    private func run() async {
        while !Task.isCancelled {
            do {
                try await prepareConnection?()
                let agents = try await client.snapshot()
                agentsBySessionId = Dictionary(
                    agents.map { ($0.sessionId, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                // Let shared per-session state (e.g. the alarm gate) forget the
                // sessions that vanished from THIS daemon since the previous
                // snapshot — only the delta, so a shared gate never evicts
                // another daemon's live episodes.
                let currentSessionIds = Set(agentsBySessionId.keys)
                let vanished = lastSnapshotSessionIds.subtracting(currentSessionIds)
                lastSnapshotSessionIds = currentSessionIds
                if !vanished.isEmpty {
                    onSessionsVanished?(vanished)
                }
                applyToWorkspaces()
                for try await transition in try await client.transitions() {
                    upsert(transition.agent)
                    applyToWorkspaces()
                    onTransition?(transition, workspace(for: transition.agent))
                }
            } catch {
                // muxad not running (or protocol failure): degrade silently.
            }
            // The stream just ended — daemon EOF, a crash, or a dropped SSH
            // forward. The last-known rows are now unverifiable, so drop them
            // and re-project: a stale `waiting`/`error` badge (and the attend
            // target that keeps jumping to it) must not outlive a dead daemon
            // or a pane that vanished without a `stopped` transition. A
            // successful reconnect repopulates from the fresh snapshot.
            if !agentsBySessionId.isEmpty {
                agentsBySessionId.removeAll()
                applyToWorkspaces()
            }
            await client.disconnect()
            // Reconnect poll: muxad has no launch notification we can
            // subscribe to, so a bounded, cancellable delay between attempts
            // is the intended behavior (15s keeps the idle cost negligible).
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func upsert(_ agent: MuxaAgent) {
        if case .stopped = agent.state {
            agentsBySessionId[agent.sessionId] = nil
        } else {
            agentsBySessionId[agent.sessionId] = agent
        }
    }

    /// The mirror workspace `agent` resolves to: session-name join first
    /// (correct across servers), pane-id join as fallback.
    private func workspace(for agent: MuxaAgent) -> Workspace? {
        if let session = agent.tmuxSession {
            return workspaceForSession(session)
        }
        if let pane = Self.paneNumber(agent.pane) {
            return workspaceForPane(pane)
        }
        return nil
    }

    /// The workspace (and tmux pane, when known) of the agent that has been
    /// blocked on the user the longest — the attend jump target. `nil` when
    /// no tracked agent needs attention or none resolves to a workspace.
    func attendTarget() -> (workspace: Workspace, tmuxPane: Int?)? {
        attendCandidate().map { ($0.workspace, $0.tmuxPane) }
    }

    /// Like ``attendTarget()`` but carries *when* the winning agent got
    /// blocked, so the observation hub can pick the longest-blocked agent
    /// across several daemons (local + one per remote host).
    func attendCandidate(now: Date = Date()) -> (workspace: Workspace, tmuxPane: Int?, blockedSince: Date)? {
        // Skip attention rows gone stale (same cutoff as the badge): a pane
        // that vanished while blocked without a `stopped` transition must not
        // keep pulling "attend" back to a dead workspace.
        let blocked = agentsBySessionId.values
            .filter { $0.state.needsAttention && !Self.isStale($0, staleAfter: Self.attentionStaleAfter, now: now) }
            .sorted { lhs, rhs in
                let l = lhs.stateEnteredDate ?? lhs.lastActivityDate ?? .distantPast
                let r = rhs.stateEnteredDate ?? rhs.lastActivityDate ?? .distantPast
                return l < r
            }
        for agent in blocked {
            if let workspace = workspace(for: agent) {
                return (
                    workspace,
                    Self.paneNumber(agent.pane),
                    agent.stateEnteredDate ?? agent.lastActivityDate ?? .distantPast
                )
            }
        }
        return nil
    }

    /// Every tracked agent whose join resolves to `workspaceId` — the data
    /// behind the agent-details view (blocked agents first, then most
    /// recently active, matching ``agentPane(inWorkspace:)``'s relevance).
    func agents(inWorkspace workspaceId: UUID) -> [MuxaAgent] {
        agentsBySessionId.values
            .filter { workspace(for: $0)?.id == workspaceId }
            .sorted { lhs, rhs in
                switch (lhs.state.needsAttention, rhs.state.needsAttention) {
                case (true, false): return true
                case (false, true): return false
                default:
                    let l = lhs.lastActivityDate ?? .distantPast
                    let r = rhs.lastActivityDate ?? .distantPast
                    return l > r
                }
            }
    }

    /// Every tracked agent carrying `tmuxSession`, including agents whose
    /// session is currently detached and therefore cannot resolve to a workspace.
    func agents(inTmuxSession tmuxSession: String) -> [MuxaAgent] {
        agentsBySessionId.values
            .filter { $0.tmuxSession == tmuxSession }
            .sorted { lhs, rhs in
                switch (lhs.state.needsAttention, rhs.state.needsAttention) {
                case (true, false): return true
                case (false, true): return false
                case (true, true):
                    let l = lhs.stateEnteredDate ?? lhs.lastActivityDate ?? .distantFuture
                    let r = rhs.stateEnteredDate ?? rhs.lastActivityDate ?? .distantFuture
                    if l != r { return l < r }
                case (false, false):
                    let l = lhs.lastActivityDate ?? lhs.startedDate ?? .distantPast
                    let r = rhs.lastActivityDate ?? rhs.startedDate ?? .distantPast
                    if l != r { return l > r }
                }
                return lhs.sessionId < rhs.sessionId
            }
    }

    /// The tmux pane of `workspaceId`'s most relevant agent — blocked agents
    /// first (longest wait first), then the most recently active — the
    /// preferred headless-prompt target. `nil` when no tracked agent
    /// resolves to this workspace.
    func agentPane(inWorkspace workspaceId: UUID) -> Int? {
        let candidates = agentsBySessionId.values.compactMap { agent -> (agent: MuxaAgent, pane: Int)? in
            guard let pane = Self.paneNumber(agent.pane) else { return nil }
            guard workspace(for: agent)?.id == workspaceId else { return nil }
            return (agent, pane)
        }
        let best = candidates.sorted { lhs, rhs in
            switch (lhs.agent.state.needsAttention, rhs.agent.state.needsAttention) {
            case (true, false): return true
            case (false, true): return false
            case (true, true):
                let l = lhs.agent.stateEnteredDate ?? .distantPast
                let r = rhs.agent.stateEnteredDate ?? .distantPast
                return l < r
            case (false, false):
                let l = lhs.agent.lastActivityDate ?? .distantPast
                let r = rhs.agent.lastActivityDate ?? .distantPast
                return l > r
            }
        }.first
        return best?.pane
    }

    /// Parses muxad's `%N` pane id into its numeric part.
    static func paneNumber(_ pane: String?) -> Int? {
        guard let pane, pane.hasPrefix("%") else { return nil }
        return Int(pane.dropFirst())
    }

    /// Regroups agents by their resolved workspace and rewrites each mirrored
    /// workspace's status row; workspaces whose agents all left get theirs
    /// cleared. Session-name join first (correct across servers), pane-id
    /// join as fallback (see `workspaceForPane`).
    private func applyToWorkspaces() {
        var byWorkspace: [UUID: (workspace: Workspace, agents: [MuxaAgent])] = [:]
        for agent in agentsBySessionId.values {
            guard let workspace = workspace(for: agent) else { continue }
            byWorkspace[workspace.id, default: (workspace, [])].agents.append(agent)
        }

        // Same-state pass through the alarm sink for EVERY tracked agent.
        // Real transitions alone lose alarms two ways: a transition that
        // fires before this service's subscribe connects exists only in the
        // snapshot, and a transition whose pane is younger than muxad's
        // inventory arrives before its workspace join resolves. The sink's
        // gate dedupes episodes, so repeated passes stay quiet; edges
        // (finished) still come only from real transitions.
        if let onTransition {
            for agent in agentsBySessionId.values {
                onTransition(
                    MuxaTransition(from: agent.state, to: agent.state, agent: agent),
                    workspace(for: agent)
                )
            }
        }

        var updated: [UUID: WeakWorkspace] = [:]
        for (workspaceId, group) in byWorkspace {
            guard let entry = Self.statusEntry(for: group.agents) else { continue }
            updated[workspaceId] = WeakWorkspace(value: group.workspace)
            // Only reassign the `@Published` entry when the *visible* summary
            // changed. `statusEntry(for:)` stamps a fresh `Date()` on every
            // call and `SidebarStatusEntry` is `Equatable` including that
            // timestamp, so an unconditional write would republish on every
            // transition of any agent and every freshness tick — the
            // orthogonal-@Published churn that thrashes the sidebar list
            // (CLAUDE.md snapshot-boundary rule).
            guard !Self.sameSummary(group.workspace.statusEntries[Self.statusEntryKey], entry) else { continue }
            group.workspace.statusEntries[Self.statusEntryKey] = entry
            #if DEBUG
            cmuxDebugLog("amux.agentStatus workspace=\(group.workspace.customTitle ?? workspaceId.uuidString) value=\"\(entry.value)\"")
            #endif
        }
        for (workspaceId, weakWorkspace) in workspacesWithEntry where updated[workspaceId] == nil {
            guard let workspace = weakWorkspace.value,
                  workspace.statusEntries[Self.statusEntryKey] != nil else { continue }
            workspace.statusEntries[Self.statusEntryKey] = nil
        }
        workspacesWithEntry = updated
    }

    /// How long a silent `working` state stays believable. Past this the
    /// agent is shown as idle: with no fresh activity the "working" claim is
    /// stale (a missed hook or dead CLI), and a perpetual working badge
    /// teaches the user to ignore the sidebar.
    static let workingStaleAfter: TimeInterval = 30 * 60

    /// How long a silent attention state (`waiting` / `error`) stays
    /// believable. Attention rows are actionable however old they normally
    /// get — a genuinely-blocked agent left overnight must still show — but a
    /// row frozen this long with zero fresh activity is almost always a dead
    /// pane (a crashed CLI, or a daemon that died without a `stopped`
    /// transition), so past this cutoff it is dropped rather than
    /// re-projected forever by the freshness tick. Deliberately far longer
    /// than ``workingStaleAfter``.
    static let attentionStaleAfter: TimeInterval = 12 * 60 * 60

    /// Whether `agent`'s current state has gone stale: its freshest evidence
    /// (last activity, else when it entered the state) is older than
    /// `staleAfter`. No timestamps at all means no staleness evidence, so the
    /// agent is never treated as stale — never hide a live agent on missing
    /// data.
    private static func isStale(_ agent: MuxaAgent, staleAfter: TimeInterval, now: Date) -> Bool {
        let freshness = agent.lastActivityDate ?? agent.stateEnteredDate
        return freshness.map { now.timeIntervalSince($0) > staleAfter } ?? false
    }

    /// Whether two of our status rows would render identically — every field
    /// the sidebar shows, ignoring the always-fresh `timestamp`. Gates the
    /// `@Published` reassignment in ``applyToWorkspaces()`` (see finding note
    /// there).
    private static func sameSummary(_ lhs: SidebarStatusEntry?, _ rhs: SidebarStatusEntry) -> Bool {
        guard let lhs else { return false }
        return lhs.key == rhs.key
            && lhs.value == rhs.value
            && lhs.icon == rhs.icon
            && lhs.color == rhs.color
            && lhs.url == rhs.url
            && lhs.priority == rhs.priority
            && lhs.format == rhs.format
    }

    /// One summary row for a session's live agents, `nil` when there is
    /// nothing worth showing (all idle/starting/stale).
    static func statusEntry(for agents: [MuxaAgent], now: Date = Date()) -> SidebarStatusEntry? {
        var working = 0, waiting = 0, errors = 0
        for agent in agents {
            switch agent.state {
            case .working:
                if !Self.isStale(agent, staleAfter: Self.workingStaleAfter, now: now) { working += 1 }
            case .waitingInput, .waitingChoice:
                if !Self.isStale(agent, staleAfter: Self.attentionStaleAfter, now: now) { waiting += 1 }
            case .error:
                if !Self.isStale(agent, staleAfter: Self.attentionStaleAfter, now: now) { errors += 1 }
            case .starting, .idle, .stopped, .unknown: break
            }
        }
        // Count phrases: the interpolated `Int` makes these keys plural-ready,
        // so the string catalog can carry per-count variations (`amux.agents.*`
        // one/other) — the English default is the singular form only.
        var parts: [String] = []
        if errors > 0 {
            parts.append(String(localized: "amux.agents.error", defaultValue: "\(errors) error"))
        }
        if waiting > 0 {
            parts.append(String(localized: "amux.agents.waiting", defaultValue: "\(waiting) waiting"))
        }
        if working > 0 {
            parts.append(String(localized: "amux.agents.working", defaultValue: "\(working) working"))
        }
        guard !parts.isEmpty else { return nil }
        // Attention states outrank progress in both the icon and the color.
        let color = errors > 0 ? "#E5484D" : (waiting > 0 ? "#F5A623" : "#30A46C")
        let icon = errors > 0 ? "exclamationmark.triangle"
            : (waiting > 0 ? "person.crop.circle.badge.questionmark" : "brain")
        return SidebarStatusEntry(
            key: statusEntryKey,
            value: parts.joined(separator: " · "),
            icon: icon,
            color: color,
            priority: 90,
            timestamp: Date()
        )
    }
}
