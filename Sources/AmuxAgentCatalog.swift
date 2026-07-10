import Foundation

/// One CLI coding agent amux knows how to detect and launch — the amux
/// analogue of orca's `TUI_AGENT_CONFIG` manifest. The catalog captures the
/// per-agent quirks (binary aliases, how an initial prompt is delivered) in
/// one table so every launch surface (socket RPC, palette, onboarding) shares
/// the same knowledge instead of hardcoding `claude` in each.
struct AmuxAgentCatalogEntry: Sendable, Equatable {
    /// Stable identifier used on the wire (`amux.launch_agent {"agent": …}`).
    let id: String
    /// Product name for UI/notifications (a product name — never localized).
    let displayName: String
    /// Binary names probed on PATH, first hit wins. The first entry is also
    /// the launch binary.
    let detectCommands: [String]
    /// How an initial prompt travels to the agent.
    enum PromptInjection: Sendable, Equatable {
        /// Appended as a (shell-quoted) positional argument: `claude 'fix x'`.
        case argv
        /// Passed via a flag: `opencode --prompt 'fix x'`.
        case flag(String)
        /// The CLI takes no startup prompt: launch first, then type the
        /// prompt into the TUI once it owns the pane.
        case typeAfterStart
    }
    let promptInjection: PromptInjection

    /// The shell line that starts this agent with `prompt` (already
    /// shell-quoted where it is embedded). For `.typeAfterStart` the prompt is
    /// NOT part of the line — the caller delivers it separately after launch.
    func launchLine(prompt: String?) -> String {
        let binary = detectCommands[0]
        guard let prompt, !prompt.isEmpty else { return binary }
        switch promptInjection {
        case .argv:
            return "\(binary) \(Self.shellSingleQuoted(prompt))"
        case .flag(let flag):
            return "\(binary) \(flag) \(Self.shellSingleQuoted(prompt))"
        case .typeAfterStart:
            return binary
        }
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The built-in agent table plus PATH detection. Detection runs the user's
/// login shell so Homebrew/nvm/fnm paths resolve exactly as they do in the
/// user's own terminal (a GUI app's inherited PATH is often bare — the same
/// gap orca papers over with its login-shell PATH refresh).
enum AmuxAgentCatalog {
    static let entries: [AmuxAgentCatalogEntry] = [
        .init(
            id: "claude", displayName: "Claude Code",
            detectCommands: ["claude"], promptInjection: .argv
        ),
        .init(
            id: "codex", displayName: "Codex",
            detectCommands: ["codex"], promptInjection: .argv
        ),
        .init(
            id: "gemini", displayName: "Gemini CLI",
            detectCommands: ["gemini"], promptInjection: .flag("-i")
        ),
        .init(
            id: "opencode", displayName: "OpenCode",
            detectCommands: ["opencode"], promptInjection: .flag("--prompt")
        ),
        .init(
            id: "cursor", displayName: "Cursor Agent",
            detectCommands: ["cursor-agent", "agent"], promptInjection: .argv
        ),
        .init(
            id: "droid", displayName: "Droid",
            detectCommands: ["droid"], promptInjection: .argv
        ),
        .init(
            id: "copilot", displayName: "GitHub Copilot CLI",
            detectCommands: ["copilot"], promptInjection: .flag("-i")
        ),
        .init(
            id: "amp", displayName: "Amp",
            detectCommands: ["amp"], promptInjection: .typeAfterStart
        ),
        .init(
            id: "goose", displayName: "Goose",
            detectCommands: ["goose"], promptInjection: .typeAfterStart
        ),
        .init(
            id: "grok", displayName: "Grok CLI",
            detectCommands: ["grok"], promptInjection: .argv
        ),
        .init(
            id: "aider", displayName: "Aider",
            detectCommands: ["aider"], promptInjection: .typeAfterStart
        ),
        .init(
            id: "crush", displayName: "Crush",
            detectCommands: ["crush"], promptInjection: .typeAfterStart
        ),
        .init(
            id: "qwen", displayName: "Qwen Code",
            detectCommands: ["qwen"], promptInjection: .argv
        ),
    ]

    static func entry(id: String) -> AmuxAgentCatalogEntry? {
        entries.first { $0.id == id.lowercased() }
    }

    /// The `sh` script probing every catalog binary in one shell invocation.
    /// Emits `<binary>=<path>` per hit and `<binary>=` per miss — a stable,
    /// order-preserving format `parseDetectionOutput` reverses.
    static func detectionScript() -> String {
        let names = entries.flatMap(\.detectCommands)
        let probes = names.map { name in
            "printf '%s=' \(AmuxAgentCatalogEntry.shellSingleQuoted(name)); "
                + "command -v \(AmuxAgentCatalogEntry.shellSingleQuoted(name)) || printf '\\n'"
        }
        return probes.joined(separator: "; ")
    }

    /// Parses ``detectionScript()`` output into binary → resolved path.
    static func parseDetectionOutput(_ output: String) -> [String: String] {
        var paths: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator])
            let path = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { paths[name] = path }
        }
        return paths
    }

    /// One detection row per catalog entry against resolved `paths`.
    static func detectionRows(paths: [String: String]) -> [[String: Any]] {
        entries.map { entry in
            let hit = entry.detectCommands.compactMap { paths[$0] }.first
            var row: [String: Any] = [
                "agent": entry.id,
                "name": entry.displayName,
                "installed": hit != nil,
            ]
            if let hit { row["path"] = hit }
            return row
        }
    }

    /// Runs ``detectionScript()`` under the user's login shell and returns the
    /// resolved binary paths. Off-main (spawns a process and waits).
    static func detectInstalled() async -> [String: String] {
        let script = detectionScript()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = await Task.detached {
            out.fileHandleForReading.readDataToEndOfFile()
        }.value
        await Task.detached { process.waitUntilExit() }.value
        return parseDetectionOutput(String(decoding: data, as: UTF8.self))
    }
}
