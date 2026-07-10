/// Immutable session-switcher state emitted after each host-level transition.
struct AmuxSessionSwitcherSnapshot: Equatable {
    let items: [AmuxSessionSwitcherItem]
    let loadingHosts: [RemoteTmuxHost]
    let failedHosts: [RemoteTmuxHost]
    let hostCount: Int
    let revision: UInt64

    var isLoading: Bool { !loadingHosts.isEmpty }
}
