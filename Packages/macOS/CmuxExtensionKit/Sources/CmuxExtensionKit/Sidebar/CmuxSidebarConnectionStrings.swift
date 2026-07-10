import Foundation

enum CmuxSidebarConnectionStrings {
    static let missingSnapshot = String(
        localized: "sidebar.extension.error.missingSnapshot",
        defaultValue: "amux did not send a workspace snapshot"
    )
    static let waitingForHost = String(
        localized: "sidebar.extension.status.waitingForHost",
        defaultValue: "Waiting for amux"
    )
    static let connectionChanged = String(
        localized: "sidebar.extension.error.connectionChanged",
        defaultValue: "amux connection changed"
    )
    static let connectionLost = String(
        localized: "sidebar.extension.error.connectionLost",
        defaultValue: "amux connection was lost"
    )
    static let missingActionResult = String(
        localized: "sidebar.extension.error.missingActionResult",
        defaultValue: "amux did not send an action result"
    )
    static let connectionClosed = String(
        localized: "sidebar.extension.error.connectionClosed",
        defaultValue: "amux connection was closed"
    )
    static let connectionInterrupted = String(
        localized: "sidebar.extension.error.connectionInterrupted",
        defaultValue: "amux connection was interrupted"
    )
    static let actionRejected = String(
        localized: "sidebar.extension.error.actionRejected",
        defaultValue: "amux did not allow that action"
    )
}
