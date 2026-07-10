import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    case listWindows
    case capturePane(Int)
    case paneState(Int)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int)
    case activityQuery(UUID)
    /// `show-options -gv prefix` — the server's actual prefix key, so the
    /// typed-input prefix interception follows a remapped prefix (C-a, …)
    /// instead of assuming the C-b default.
    case prefixKey
    case other
}
