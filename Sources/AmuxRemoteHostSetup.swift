import Foundation

/// Inspects and provisions the muxa observation stack on a remote SSH host.
///
/// The remote half of agent observation needs three things on the host:
/// the `muxa` CLI, a running `muxad`, and agent hooks wired into the CLIs
/// (Claude Code / Codex / …). ``inspect(host:)`` reports all of it in one
/// SSH round trip over the host's shared ControlMaster; ``wireHooks(host:)``
/// runs the same hooks-only `muxa init` the local onboarding uses (which
/// also starts `muxad` when absent — `--start-daemon` defaults on). When the
/// CLI itself is missing, provisioning is a guided instruction, not an
/// action: amux bundles macOS binaries only, so a Linux host installs muxa
/// with cargo.
actor AmuxRemoteHostSetup {
    /// One host's observation-stack status.
    struct Report: Equatable {
        /// `muxa --version` output, `nil` when the CLI is not installed.
        var muxaVersion: String?
        /// Whether a muxad socket answers on the host.
        var muxadRunning: Bool
        /// Whether Claude Code's settings reference muxa hooks.
        var claudeHooksWired: Bool
        /// Whether Codex's config references muxa.
        var codexHooksWired: Bool
        /// Whether muxa's own desktop notifier is enabled (opt-in; when on,
        /// the host alerts locally in addition to amux's Mac-side alarms).
        var notifierEnabled: Bool
    }

    private let sshExecutablePath: String

    init(sshExecutablePath: String = "/usr/bin/ssh") {
        self.sshExecutablePath = sshExecutablePath
    }

    /// The remote argv that prints the observation-stack status as KEY=VALUE
    /// lines (one SSH round trip; every check is best-effort and read-only).
    static var inspectionArgv: [String] {
        let script =
            "if command -v muxa >/dev/null 2>&1; then MUXA_BIN=\"$(command -v muxa)\"; " +
            "elif [ -x \"$HOME/.cargo/bin/muxa\" ]; then MUXA_BIN=\"$HOME/.cargo/bin/muxa\"; " +
            "else MUXA_BIN=\"\"; fi; " +
            "if [ -n \"$MUXA_BIN\" ]; then printf 'MUXA_VERSION=%s\\n' \"$(\"$MUXA_BIN\" --version 2>/dev/null)\"; " +
            "else printf 'MUXA_VERSION=\\n'; fi; " +
            "SOCK=\"${XDG_RUNTIME_DIR:-}/muxa.sock\"; [ -S \"$SOCK\" ] || SOCK=\"/tmp/muxa-$(id -u).sock\"; " +
            "if [ -S \"$SOCK\" ]; then printf 'MUXAD=running\\n'; else printf 'MUXAD=absent\\n'; fi; " +
            "if grep -qs muxa \"$HOME/.claude/settings.json\"; then printf 'HOOKS_CLAUDE=wired\\n'; else printf 'HOOKS_CLAUDE=absent\\n'; fi; " +
            "if grep -qs muxa \"$HOME/.codex/config.toml\"; then printf 'HOOKS_CODEX=wired\\n'; else printf 'HOOKS_CODEX=absent\\n'; fi; " +
            "awk '/^\\[notifier\\]/{f=1;next} /^\\[/{f=0} f && /^[ \\t]*enabled[ \\t]*=[ \\t]*true/{print \"NOTIFIER=enabled\"; exit}' " +
            "\"${XDG_CONFIG_HOME:-$HOME/.config}/muxa/config.toml\" 2>/dev/null; true"
        return ["/bin/sh", "-c", script]
    }

    /// The remote argv that wires agent hooks (and starts muxad when absent)
    /// — the same hooks-only component set the local onboarding installs.
    static var wireHooksArgv: [String] {
        let script =
            "if command -v muxa >/dev/null 2>&1; then MUXA_BIN=\"$(command -v muxa)\"; " +
            "elif [ -x \"$HOME/.cargo/bin/muxa\" ]; then MUXA_BIN=\"$HOME/.cargo/bin/muxa\"; " +
            "else echo 'muxa: not installed' >&2; exit 127; fi; " +
            "\"$MUXA_BIN\" init --component claude-hooks,codex-hooks,gemini-hooks,opencode-hooks --yes"
        return ["/bin/sh", "-c", script]
    }

    /// Parses ``inspectionArgv``'s stdout into a ``Report`` (login-shell
    /// banner noise is ignored: only recognized KEY=VALUE lines count).
    static func parseReport(fromProbeOutput output: String) -> Report {
        var report = Report(
            muxaVersion: nil,
            muxadRunning: false,
            claudeHooksWired: false,
            codexHooksWired: false,
            notifierEnabled: false
        )
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("MUXA_VERSION=") {
                let value = String(trimmed.dropFirst("MUXA_VERSION=".count))
                report.muxaVersion = value.isEmpty ? nil : value
            } else if trimmed == "MUXAD=running" {
                report.muxadRunning = true
            } else if trimmed == "HOOKS_CLAUDE=wired" {
                report.claudeHooksWired = true
            } else if trimmed == "HOOKS_CODEX=wired" {
                report.codexHooksWired = true
            } else if trimmed == "NOTIFIER=enabled" {
                report.notifierEnabled = true
            }
        }
        return report
    }

    /// Inspects `host`'s observation stack over its shared ControlMaster.
    func inspect(host: RemoteTmuxHost) async throws -> Report {
        let result = try await run(remoteArgv: Self.inspectionArgv, host: host)
        guard result.exitCode == 0 else {
            throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return Self.parseReport(fromProbeOutput: result.stdout)
    }

    /// Wires agent hooks on `host` (idempotent; also starts muxad when
    /// absent). Returns the remote command's output tail for the report UI.
    /// Throws with exit 127 stderr when the muxa CLI is missing remotely.
    func wireHooks(host: RemoteTmuxHost) async throws -> String {
        let result = try await run(remoteArgv: Self.wireHooksArgv, host: host)
        guard result.exitCode == 0 else {
            throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(remoteArgv: [String], host: RemoteTmuxHost) async throws -> RemoteTmuxCommandResult {
        try host.ensureControlSocketDirectory()
        return try await RemoteTmuxSSHTransport.runProcess(
            executable: sshExecutablePath,
            arguments: host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
                + ["--", host.destination]
                + [remoteArgv.map(RemoteTmuxHost.shellSingleQuoted).joined(separator: " ")]
        )
    }
}
