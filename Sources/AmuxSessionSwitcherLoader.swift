/// Loads one tmux host and joins its sessions with the matching muxa agents.
@MainActor
final class AmuxSessionSwitcherLoader: AmuxSessionSwitcherLoading {
    private let remoteTmuxController: RemoteTmuxController
    private let agentObservation: AmuxAgentObservationHub

    init(
        remoteTmuxController: RemoteTmuxController,
        agentObservation: AmuxAgentObservationHub
    ) {
        self.remoteTmuxController = remoteTmuxController
        self.agentObservation = agentObservation
    }

    func load(host: RemoteTmuxHost) async throws -> [AmuxSessionSwitcherItem] {
        try Task.checkCancellation()
        let sessions = try await remoteTmuxController.listSessions(host: host)
        try Task.checkCancellation()
        return sessions.map { session in
            AmuxSessionSwitcherItem(
                host: host,
                session: session,
                agents: agentObservation.agents(
                    host: host,
                    inTmuxSession: session.name
                )
            )
        }
    }
}
