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

    func kindLabel(isOpen: Bool) -> String {
        isOpen
            ? String(localized: "amux.sessionSwitcher.kind.open", defaultValue: "Open tmux")
            : String(localized: "amux.sessionSwitcher.kind.available", defaultValue: "Available tmux")
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
        var parts: [String] = []
        if let agent = AmuxSessionSwitcherItem.orderedAgents(agents).first {
            parts.append(
                String(
                    format: String(
                        localized: "amux.sessionSwitcher.subtitle.agentSeparator",
                        defaultValue: "%1$@ · %2$@"
                    ),
                    AmuxAgentAlarmPolicy.displayName(for: agent.kind),
                    agentStateLabel(agent.state)
                )
            )
        }
        if let session, session.windowCount > 0 {
            let windowCount = session.windowCount
            let format = windowCount == 1
                ? String(localized: "amux.sessionSwitcher.windowCount.one", defaultValue: "%lld window")
                : String(localized: "amux.sessionSwitcher.windowCount.other", defaultValue: "%lld windows")
            parts.append(String(format: format, Int64(windowCount)))
            if let activityDate = AmuxSessionSwitcherItem.mostRecentActivityDate(
                session: session,
                agents: agents
            ) {
                parts.append(activityDate.formatted(.relative(presentation: .named)))
            }
        }
        let partSeparator = String(
            localized: "amux.sessionSwitcher.subtitle.partSeparator",
            defaultValue: " • "
        )
        return (parts.isEmpty ? [hostLabel(host)] : parts).joined(separator: partSeparator)
    }

    func statusText(
        loadingHosts: [RemoteTmuxHost],
        failedHosts: [RemoteTmuxHost]
    ) -> String? {
        var parts: [String] = []
        if !loadingHosts.isEmpty {
            parts.append(String(
                format: String(
                    localized: "amux.sessionSwitcher.status.loadingHosts",
                    defaultValue: "Loading: %@"
                ),
                loadingHosts.map(hostLabel).joined(separator: ", ")
            ))
        }
        if !failedHosts.isEmpty {
            parts.append(String(
                format: String(
                    localized: "amux.sessionSwitcher.status.unavailableHosts",
                    defaultValue: "Unavailable: %@"
                ),
                failedHosts.map(hostLabel).joined(separator: ", ")
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
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
