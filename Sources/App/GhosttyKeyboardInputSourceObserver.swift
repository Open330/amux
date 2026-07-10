import AppKit
import Carbon
import Foundation

/// Bridges both macOS input-source notifications into one Ghostty keymap refresh.
final class GhosttyKeyboardInputSourceObserver {
    private let localCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let localToken: NSObjectProtocol
    private let distributedToken: NSObjectProtocol

    init(
        localCenter: NotificationCenter = .default,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        onChange: @escaping () -> Void
    ) {
        self.localCenter = localCenter
        self.distributedCenter = distributedCenter
        localToken = localCenter.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChange()
        }
        distributedToken = distributedCenter.addObserver(
            forName: Notification.Name(
                rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
            ),
            object: nil,
            queue: .main
        ) { _ in
            onChange()
        }
    }

    deinit {
        localCenter.removeObserver(localToken)
        distributedCenter.removeObserver(distributedToken)
    }
}
