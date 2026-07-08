import Foundation

/// Manages the opt-in launchd user agent that keeps the bundled `muxad`
/// running so agent-activity observation outlives the app (R02 §3.3).
///
/// Coexistence is the core rule: if a muxad is already answering on the
/// standard socket (the user's own `cargo`-installed daemon), amux uses that
/// and refuses to install a competing agent. Installation is always explicit
/// (a user action), never automatic — it writes a `LaunchAgents` plist and
/// bootstraps it, both reversible via ``uninstall()``.
///
/// The launchctl calls are the outside-world seam; the plist construction and
/// path logic are pure and unit-testable via ``plistContents(muxadPath:)``.
struct AmuxMuxadLaunchAgent {
    /// The launchd label (and plist basename).
    static let label = "com.open330.amux.muxad"

    /// Path to the per-user LaunchAgents plist.
    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    /// Whether the LaunchAgent plist is currently installed.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The launchd plist that runs `muxadPath` at login and keeps it alive.
    /// `RunAtLoad` + `KeepAlive` make muxad the persistent observer; stdout/
    /// stderr go to a log under the user's caches.
    static func plistContents(muxadPath: String) -> String {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/amux-muxad.log").path
        // Values are amux-controlled (a bundled binary path + fixed strings),
        // so a plain plist template is safe — no untrusted interpolation.
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(muxadPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    /// Outcome of an ``install(muxadPath:daemonAlreadyRunning:)`` attempt.
    enum InstallResult: Equatable {
        /// Installed and bootstrapped the agent for `muxadPath`.
        case installed
        /// Skipped because a muxad is already answering — amux uses it.
        case deferredToRunningDaemon
        /// No bundled muxad to install (unbundled dev build).
        case noBundledDaemon
        /// launchctl bootstrap failed; carries stderr.
        case failed(String)
    }

    /// Installs + bootstraps the agent, honoring coexistence.
    ///
    /// - Parameters:
    ///   - muxadPath: the bundled muxad (nil in an unbundled dev build).
    ///   - daemonAlreadyRunning: whether a muxad already answers on the
    ///     socket (caller probes via `MuxaClient.isReachable()`).
    func install(muxadPath: String?, daemonAlreadyRunning: Bool) -> InstallResult {
        guard !daemonAlreadyRunning else { return .deferredToRunningDaemon }
        guard let muxadPath else { return .noBundledDaemon }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.plistContents(muxadPath: muxadPath).write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed("write plist: \(error)")
        }
        let (ok, err) = Self.runLaunchctl(["bootstrap", Self.guiDomain, plistURL.path])
        return ok ? .installed : .failed(err)
    }

    /// Boots the agent out and removes its plist. Safe to call when absent.
    func uninstall() {
        _ = Self.runLaunchctl(["bootout", "\(Self.guiDomain)/\(Self.label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// `gui/<uid>` — the launchd domain for per-user agents.
    private static var guiDomain: String { "gui/\(getuid())" }

    /// Runs `launchctl` with `arguments`; returns (success, stderr).
    private static func runLaunchctl(_ arguments: [String]) -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "\(error)")
        }
        let err = String(
            decoding: errPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (process.terminationStatus == 0, err)
    }
}
