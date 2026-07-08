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
        workspaceForPane: @escaping @MainActor (Int) -> Workspace?
    ) {
        self.client = client
        self.workspaceForSession = workspaceForSession
        self.workspaceForPane = workspaceForPane
    }

    /// Starts the snapshot+subscribe loop (idempotent).
    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let agents = try await client.snapshot()
                agentsBySessionId = Dictionary(
                    agents.map { ($0.sessionId, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                applyToWorkspaces()
                for try await transition in try await client.transitions() {
                    upsert(transition.agent)
                    applyToWorkspaces()
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

    /// The workspace (and tmux pane, when known) of the agent that has been
    /// blocked on the user the longest — the attend jump target. `nil` when
    /// no tracked agent needs attention or none resolves to a workspace.
    func attendTarget() -> (workspace: Workspace, tmuxPane: Int?)? {
        let blocked = agentsBySessionId.values
            .filter { $0.state.needsAttention }
            .sorted { lhs, rhs in
                let l = lhs.stateEnteredDate ?? lhs.lastActivityDate ?? .distantPast
                let r = rhs.stateEnteredDate ?? rhs.lastActivityDate ?? .distantPast
                return l < r
            }
        for agent in blocked {
            let pane = Self.paneNumber(agent.pane)
            let workspace: Workspace?
            if let session = agent.tmuxSession {
                workspace = workspaceForSession(session)
            } else if let pane {
                workspace = workspaceForPane(pane)
            } else {
                workspace = nil
            }
            if let workspace {
                return (workspace, pane)
            }
        }
        return nil
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
            let workspace: Workspace?
            if let session = agent.tmuxSession {
                workspace = workspaceForSession(session)
            } else if let pane = Self.paneNumber(agent.pane) {
                workspace = workspaceForPane(pane)
            } else {
                workspace = nil
            }
            guard let workspace else { continue }
            byWorkspace[workspace.id, default: (workspace, [])].agents.append(agent)
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

    /// One summary row for a session's live agents, `nil` when there is
    /// nothing worth showing (all idle/starting).
    static func statusEntry(for agents: [MuxaAgent]) -> SidebarStatusEntry? {
        var working = 0, waiting = 0, errors = 0
        for agent in agents {
            switch agent.state {
            case .working: working += 1
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
