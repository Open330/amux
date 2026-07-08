import AppKit
import CmuxMuxa

/// First-run onboarding for amux's agent integration: installs the opt-in
/// muxad LaunchAgent and wires the agent CLIs' hooks (via bundled
/// `muxa init`) so Claude Code / Codex / Gemini report their state to amux.
///
/// Every step is consent-gated — the flow is a plain confirmation dialog, and
/// nothing is written until the user chooses "Set Up". Shown once on first
/// launch (tracked in `UserDefaults`) and re-runnable from the Command
/// Palette. System mutations (launchctl, hook files) live behind the
/// `runMuxaInit` seam so the decision logic is testable.
@MainActor
struct AmuxOnboarding {
    /// `UserDefaults` key marking that first-run onboarding was offered.
    static let completedDefaultsKey = "amux.onboarding.offered.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether first-run onboarding has already been offered.
    var hasBeenOffered: Bool {
        defaults.bool(forKey: Self.completedDefaultsKey)
    }

    /// Presents the first-run prompt if it hasn't been offered yet, marking it
    /// offered either way (so a declined prompt doesn't nag every launch).
    func presentIfFirstRun() {
        guard !hasBeenOffered else { return }
        defaults.set(true, forKey: Self.completedDefaultsKey)
        present(isFirstRun: true)
    }

    /// Presents the onboarding prompt (the Command Palette entry point).
    func present(isFirstRun: Bool = false) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "amux.onboarding.title",
            defaultValue: "Set Up amux Agent Integration"
        )
        alert.informativeText = String(
            localized: "amux.onboarding.body",
            defaultValue: "amux can keep a background daemon running and wire your agent CLIs (Claude Code, Codex, Gemini) to report their status — so workspaces show live agent badges and you can jump to a blocked agent. This edits your agent CLI settings and installs a login item. You can undo it anytime from the Command Palette."
        )
        alert.addButton(withTitle: String(localized: "amux.onboarding.setUp", defaultValue: "Set Up"))
        alert.addButton(withTitle: String(localized: "amux.onboarding.notNow", defaultValue: "Not Now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runSetup()
    }

    /// Runs the consented setup: install the LaunchAgent (coexisting with a
    /// running muxad) and wire agent hooks via bundled `muxa init`.
    private func runSetup() {
        Task { @MainActor in
            let running = await MuxaClient().isReachable()
            let agentResult = AmuxMuxadLaunchAgent().install(
                muxadPath: RemoteTmuxHost.bundledMuxadPath(),
                daemonAlreadyRunning: running
            )
            let hooksResult = Self.runMuxaInit()
            Self.presentResult(agent: agentResult, hooks: hooksResult)
        }
    }

    /// Outcome of the `muxa init` hook-wiring step.
    enum HooksResult: Equatable {
        case wired
        case noBundledCli
        case failed(String)
    }

    /// The muxa init components amux wires: agent hooks ONLY. amux manages
    /// its own daemon (LaunchAgent) and runs an isolated `-f /dev/null` tmux
    /// server, so it deliberately does NOT let `muxa init` edit the user's
    /// `~/.tmux.conf` (tmux-statusline/popup) or install muxa's competing
    /// `muxad-launchd` agent — verified via `muxa init --dry-run`.
    static let hookComponents = "claude-hooks,codex-hooks,gemini-hooks,opencode-hooks"

    /// Runs bundled `muxa init` to wire agent hooks non-interactively.
    static func runMuxaInit() -> HooksResult {
        guard let muxa = RemoteTmuxHost.bundledMuxaCliPath() else { return .noBundledCli }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: muxa)
        process.arguments = [
            "init", "--component", hookComponents, "--yes",
            "--start-daemon=false",
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed("\(error)")
        }
        if process.terminationStatus == 0 { return .wired }
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return .failed(err.isEmpty ? "muxa init exited \(process.terminationStatus)" : err)
    }

    /// Reverses the integration: uninstall the LaunchAgent and run
    /// `muxa init --uninstall`.
    static func runUninstall() {
        AmuxMuxadLaunchAgent().uninstall()
        if let muxa = RemoteTmuxHost.bundledMuxaCliPath() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: muxa)
            // Scope the uninstall to exactly the components amux wired, so we
            // don't strip muxa config the user set up independently.
            process.arguments = ["init", "--uninstall", "--component", hookComponents, "--yes"]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    private static func presentResult(
        agent: AmuxMuxadLaunchAgent.InstallResult,
        hooks: HooksResult
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "amux.onboarding.doneTitle", defaultValue: "amux Setup")
        var lines: [String] = []
        switch agent {
        case .installed:
            lines.append(String(localized: "amux.onboarding.daemonInstalled", defaultValue: "• Background daemon installed."))
        case .deferredToRunningDaemon:
            lines.append(String(localized: "amux.onboarding.daemonRunning", defaultValue: "• Using your already-running muxad."))
        case .noBundledDaemon:
            lines.append(String(localized: "amux.onboarding.daemonMissing", defaultValue: "• No bundled daemon in this build."))
        case .failed:
            lines.append(String(localized: "amux.onboarding.daemonFailed", defaultValue: "• Background daemon could not be installed."))
        }
        switch hooks {
        case .wired:
            lines.append(String(localized: "amux.onboarding.hooksWired", defaultValue: "• Agent hooks wired."))
        case .noBundledCli:
            lines.append(String(localized: "amux.onboarding.hooksMissing", defaultValue: "• No bundled muxa CLI to wire hooks."))
        case .failed:
            lines.append(String(localized: "amux.onboarding.hooksFailed", defaultValue: "• Agent hooks could not be wired."))
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }
}
