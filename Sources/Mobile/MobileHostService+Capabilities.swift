import Foundation

extension MobileHostService {
    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache, the network status gate, and `TerminalController`'s
    /// full status) reads this so the lists cannot drift; iOS gates features
    /// like rename/pin/read-state/close on the entries present here.
    ///
    /// Hosted dogfood feedback is intentionally not advertised by amux. The
    /// inherited Stack-authenticated service is outside the distribution
    /// boundary until Open330 provides its own endpoint and credentials.
    nonisolated static var mobileHostCapabilities: [String] {
        [
            "events.v1",
            "notification.badge.v1",
            "notification.dismiss.v1",
            "notification.reconcile.v1",
            "terminal.bytes.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            // The workspace list carries group sections (group_id per workspace +
            // a top-level groups array) and the host accepts
            // workspace.group.collapse/expand from mobile. iOS feature-detects
            // this to render collapsible groups only against a Mac that emits them.
            "workspace.groups.v1",
        ]
    }
}
