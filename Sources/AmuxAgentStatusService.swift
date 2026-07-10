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
    /// Live agent rows by muxad session id (agent-CLI session, not tmux).
    private var agentsBySessionId: [String: MuxaAgent] = [:]
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
        onTransition: (@MainActor (MuxaTransition, Workspace?) -> Void)? = nil
    ) {
        self.client = client
        self.workspaceForSession = workspaceForSession
        self.workspaceForPane = workspaceForPane
        self.prepareConnection = prepareConnection
        self.onTransition = onTransition
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
                applyToWorkspaces()
                for try await transition in try await client.transitions() {
                    upsert(transition.agent)
                    applyToWorkspaces()
                    onTransition?(transition, workspace(for: transition.agent))
                }
            } catch {
                // muxad not running (or protocol failure): degrade silently.
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
    func attendCandidate() -> (workspace: Workspace, tmuxPane: Int?, blockedSince: Date)? {
        let blocked = agentsBySessionId.values
            .filter { $0.state.needsAttention }
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
            group.workspace.statusEntries[Self.statusEntryKey] = entry
            updated[workspaceId] = WeakWorkspace(value: group.workspace)
            #if DEBUG
            cmuxDebugLog("amux.agentStatus workspace=\(group.workspace.customTitle ?? workspaceId.uuidString) value=\"\(entry.value)\"")
            #endif
        }
        for (workspaceId, weakWorkspace) in workspacesWithEntry where updated[workspaceId] == nil {
            weakWorkspace.value?.statusEntries[Self.statusEntryKey] = nil
        }
        workspacesWithEntry = updated
    }

    /// How long a silent `working` state stays believable. Past this the
    /// agent is shown as idle: with no fresh activity the "working" claim is
    /// stale (a missed hook or dead CLI), and a perpetual working badge
    /// teaches the user to ignore the sidebar. Attention states (waiting /
    /// error) never decay — they stay actionable however old they are.
    static let workingStaleAfter: TimeInterval = 30 * 60

    /// One summary row for a session's live agents, `nil` when there is
    /// nothing worth showing (all idle/starting).
    static func statusEntry(for agents: [MuxaAgent], now: Date = Date()) -> SidebarStatusEntry? {
        var working = 0, waiting = 0, errors = 0
        for agent in agents {
            switch agent.state {
            case .working:
                let freshness = agent.lastActivityDate ?? agent.stateEnteredDate
                let isStale = freshness.map { now.timeIntervalSince($0) > Self.workingStaleAfter } ?? false
                if !isStale { working += 1 }
            case .waitingInput, .waitingChoice: waiting += 1
            case .error: errors += 1
            case .starting, .idle, .stopped, .unknown: break
            }
        }
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
