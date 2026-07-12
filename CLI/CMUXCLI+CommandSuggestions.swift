import Foundation

extension CMUXCLI {
    static let amuxUsage = """
    Usage:
      amux sync tmux [on|off|status] [--json]
      amux ssh <host> [--sync|--wire|--inspect|--unsync] [--port <n>] [--identity <path>] [--focus|--no-focus]

    Examples:
      amux sync tmux
      amux sync tmux off
      amux ssh jiun-mini --inspect
      amux ssh jiun-mini --wire
    """

    static let amuxSyncUsage = """
    Usage:
      amux sync tmux [on|off|status] [--json]

    Mirror localhost tmux sessions into amux workspaces, or report the current sync state.
    """

    static var amuxSSHUsage: String {
        String(localized: "cli.help.amuxSshRemoteSetup", defaultValue: """
        Usage: amux ssh <host> [--sync|--wire|--inspect|--unsync] [flags]

        Inspect or configure an amux remote host over SSH. The default --sync action
        discovers tmux sessions, verifies muxa and muxad, and synchronizes the host's
        tmux sessions with amux. Use --inspect for a read-only status report.

        Flags:
          --sync               Discover and synchronize remote tmux sessions (default)
          --wire               Install or refresh supported remote agent hooks
          --inspect            Report muxa, muxad, hooks, and tmux sessions without changing them
          --unsync             Stop synchronizing this host's tmux sessions
          --port <n>           SSH port
          --identity <path>    SSH identity file path
          --focus              Activate the synchronized mirror window
          --no-focus           Do not activate the synchronized mirror window

        Examples:
          amux ssh my-host --inspect
          amux ssh my-host --sync
          amux ssh dev@my-host --wire --port 2222 --identity ~/.ssh/id_ed25519
          amux ssh my-host --unsync
        """)
    }

    func unknownCommandError(_ command: String) -> CLIError {
        var message = "Unknown command '\(command)'."
        if let suggestion = suggestedCommandName(for: command) {
            message += " Did you mean '\(suggestion)'?"
        }
        message += " Run 'amux --help' for the full command list."
        return CLIError(message: message, exitCode: 2)
    }

    private func suggestedCommandName(for command: String) -> String? {
        var bestName: String?
        var bestDistance = Int.max

        for candidate in Self.topLevelCommandNames where !candidate.hasPrefix("__") {
            let distance = editDistance(command, candidate)
            guard distance > 0, distance <= 2, distance < candidate.count else { continue }
            if distance < bestDistance || (distance == bestDistance && candidate < (bestName ?? candidate)) {
                bestName = candidate
                bestDistance = distance
            }
        }

        return bestName
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for (leftIndex, leftCharacter) in left.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current[rightIndex + 1] = previous[rightIndex]
                } else {
                    current[rightIndex + 1] = min(min(previous[rightIndex + 1], current[rightIndex]), previous[rightIndex]) + 1
                }
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    static let topLevelCommandNames: Set<String> = [
        "__codex-teams-watch",
        "__internal_flags",
        "__tmux-compat",
        "agent-hibernation",
        "ai-accounts",
        "amux",
        "auth",
        "bind-key",
        "break-pane",
        "browser",
        "browser-back",
        "browser-forward",
        "browser-reload",
        "browser-status",
        "capabilities",
        "capture-pane",
        "claude-hook",
        "claude-teams",
        "clear-history",
        "clear-log",
        "clear-notifications",
        "clear-progress",
        "clear-status",
        "close-surface",
        "close-window",
        "close-workspace",
        "cloud",
        "codex",
        "codex-hook",
        "codex-teams",
        "config",
        "copy-mode",
        "current-window",
        "current-workspace",
        "debug-terminals",
        "detach-tab",
        "diff",
        "disable-browser",
        "dismiss-notification",
        "display-message",
        "docs",
        "drag-surface-to-split",
        "enable-browser",
        "events",
        "feedback",
        "feed",
        "feed-hook",
        "find-window",
        "focus-pane",
        "focus-panel",
        "focus-webview",
        "focus-window",
        "get-url",
        "help",
        "hooks",
        "identify",
        "is-webview-focused",
        "join-pane",
        "jump-to-unread",
        "last-pane",
        "last-window",
        "list-buffers",
        "list-log",
        "list-notifications",
        "list-pane-surfaces",
        "list-panels",
        "list-panes",
        "list-status",
        "list-windows",
        "list-workspaces",
        "log",
        "login",
        "logout",
        "markdown",
        "mark-notification-read",
        "memory",
        "mobile",
        "move-surface",
        "move-tab-to-new-workspace",
        "move-workspace-to-window",
        "navigate",
        "new-pane",
        "new-split",
        "new-surface",
        "new-window",
        "new-workspace",
        "next-window",
        "notify",
        "omc",
        "omo",
        "omx",
        "open",
        "open-browser",
        "open-notification",
        "paste-buffer",
        "ping",
        "pipe-pane",
        "popup",
        "previous-window",
        "read-screen",
        "refresh-surfaces",
        "reload-config",
        "remote-daemon-status",
        "rename-tab",
        "rename-window",
        "rename-workspace",
        "reorder-surface",
        "reorder-workspace",
        "reorder-workspaces",
        "resize-pane",
        "respawn-pane",
        "restore-session",
        "right-sidebar",
        "rpc",
        "select-workspace",
        "send",
        "send-key",
        "send-key-panel",
        "send-panel",
        "set-app-focus",
        "set-buffer",
        "set-hook",
        "set-progress",
        "set-status",
        "settings",
        "setup-hooks",
        "shortcuts",
        "simulate-app-active",
        "sidebar",
        "sidebar-state",
        "split-off",
        "ssh",
        "ssh-pty-attach",
        "ssh-session-attach",
        "ssh-session-cleanup",
        "ssh-session-end",
        "ssh-session-list",
        "ssh-tmux",
        "surface",
        "surface-health",
        "surface-resume",
        "swap-pane",
        "sync",
        "tab-action",
        "themes",
        "top",
        "tree",
        "trigger-flash",
        "unbind-key",
        "uninstall-hooks",
        "version",
        "vm",
        "vm-pty-attach",
        "vm-pty-connect",
        "vm-ssh-attach",
        "wait-for",
        "welcome",
        "workspace",
        "workspace-action",
        "workspace-group",
    ]
}
