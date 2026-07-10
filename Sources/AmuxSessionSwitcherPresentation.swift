import CmuxMuxa
import Foundation

/// Localized labels and search terms for tmux session switcher rows.
struct AmuxSessionSwitcherPresentation {
    func rowTitle(name: String, host: RemoteTmuxHost) -> String {
        String(
            format: String(
                localized: "amux.sessionSwitcher.rowTitle",
                defaultValue: "%1$@ · %2$@"
            ),
            name,
            hostLabel(host)
        )
    }

    func hostLabel(_ host: RemoteTmuxHost) -> String {
        switch host.kind {
        case .localAmux:
            return String(
                localized: "amux.sessionSwitcher.host.amuxLocal",
                defaultValue: "amux local"
            )
        case .localDefault:
            return String(
                localized: "amux.sessionSwitcher.host.localhost",
                defaultValue: "localhost"
            )
        case .ssh:
            return host.destination
        }
    }

    func kindLabel(isOpen: Bool, agents: [MuxaAgent]) -> String {
        let kind = isOpen
            ? String(localized: "amux.sessionSwitcher.kind.open", defaultValue: "Open tmux")
            : String(localized: "amux.sessionSwitcher.kind.available", defaultValue: "Available tmux")
        guard let agent = AmuxSessionSwitcherItem.orderedAgents(agents).first else { return kind }
        return String(
            format: String(
                localized: "amux.sessionSwitcher.kindWithState",
                defaultValue: "%1$@ · %2$@"
            ),
            kind,
            agentStateLabel(agent.state)
        )
    }

    func agentStateLabel(_ state: MuxaAgentState) -> String {
        switch state {
        case .starting:
            return String(localized: "amux.sessionSwitcher.state.starting", defaultValue: "Starting")
        case .working:
            return String(localized: "amux.sessionSwitcher.state.working", defaultValue: "Working")
        case .idle:
            return String(localized: "amux.sessionSwitcher.state.idle", defaultValue: "Idle")
        case .waitingInput:
            return String(localized: "amux.sessionSwitcher.state.waitingInput", defaultValue: "Waiting for input")
        case .waitingChoice:
            return String(localized: "amux.sessionSwitcher.state.waitingChoice", defaultValue: "Waiting for choice")
        case .error:
            return String(localized: "amux.sessionSwitcher.state.error", defaultValue: "Error")
        case .stopped:
            return String(localized: "amux.sessionSwitcher.state.stopped", defaultValue: "Stopped")
        case .unknown(let raw):
            return raw
        }
    }

    func subtitle(
        host: RemoteTmuxHost,
        session: RemoteTmuxSession?,
        agents: [MuxaAgent]
    ) -> String {
        var parts = [hostLabel(host)]
        if let agent = AmuxSessionSwitcherItem.orderedAgents(agents).first {
            parts.append(
                "\(AmuxAgentAlarmPolicy.displayName(for: agent.kind)) · "
                    + agentStateLabel(agent.state)
            )
        }
        if let session {
            let windowCount = session.windowCount
            let format = windowCount == 1
                ? String(localized: "amux.sessionSwitcher.windowCount.one", defaultValue: "%lld window")
                : String(localized: "amux.sessionSwitcher.windowCount.other", defaultValue: "%lld windows")
            parts.append(String(format: format, Int64(windowCount)))
            let item = AmuxSessionSwitcherItem(host: host, session: session, agents: agents)
            if let activityDate = item.mostRecentActivityDate {
                parts.append(activityDate.formatted(.relative(presentation: .named)))
            }
        }
        return parts.joined(separator: " • ")
    }

    func searchKeywords(
        host: RemoteTmuxHost,
        sessionName: String,
        agents: [MuxaAgent]
    ) -> [String] {
        var keywords = [
            "amux",
            "tmux",
            "session",
            "workspace",
            "open",
            "detached",
            "attach",
            sessionName,
            host.destination,
            hostLabel(host)
        ]
        if host.kind == .ssh { keywords.append("ssh") }
        for agent in agents {
            keywords.append(contentsOf: [
                agent.kind.rawValue,
                AmuxAgentAlarmPolicy.displayName(for: agent.kind),
                agent.state.rawValue,
                agentStateLabel(agent.state)
            ])
            keywords.append(contentsOf: [
                agent.cwd,
                agent.lastPrompt,
                agent.lastNotification,
                agent.lastResponse,
                agent.model
            ].compactMap { $0 })
        }
        return keywords
    }
}
