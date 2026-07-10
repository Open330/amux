/// Loads the sessions discoverable on one tmux endpoint.
@MainActor
protocol AmuxSessionSwitcherLoading: AnyObject {
    func load(host: RemoteTmuxHost) async throws -> [AmuxSessionSwitcherItem]
}
