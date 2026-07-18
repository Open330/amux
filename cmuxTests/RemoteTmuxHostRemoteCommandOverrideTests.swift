import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every ssh-tmux invocation supplies its own remote command (`true` for
/// interactive auth, `tmux -CC …` for the mirror, one-shot discovery
/// commands), so a host ssh_config `RemoteCommand` would abort them all with
/// OpenSSH's "Cannot execute command-line and remote command." (exit 255,
/// https://github.com/manaflow-ai/cmux/issues/7246) — the shared control
/// args must clear it with `-o RemoteCommand=none`.
@Suite struct RemoteTmuxHostRemoteCommandOverrideTests {
    @Test(arguments: [true, false])
    func controlArgsOverrideHostConfiguredRemoteCommand(batchMode: Bool) {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: batchMode)
        #expect(consecutive(args, "-o", "RemoteCommand=none"))
    }

    @Test func controlModeArgumentsOverrideHostRemoteCommandAndKeepForcedTTY() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.controlModeArguments(sessionName: "work", createIfMissing: false)
        #expect(consecutive(args, "-o", "RemoteCommand=none"))
        // The remote `tmux attach` still needs its forced PTY.
        #expect(args.first == "-tt")
    }

    @Test func interactiveAuthInvocationOverridesHostConfiguredRemoteCommand() {
        let host = RemoteTmuxHost(destination: "user@host")
        #expect(consecutive(host.interactiveAuthInvocation(), "-o", "RemoteCommand=none"))
    }

    @Test func localDefaultHostIsDistinctFromSSHAndAmuxLocalEndpoints() {
        let localDefault = RemoteTmuxHost.localDefault()
        #expect(localDefault.kind == .localDefault)
        #expect(localDefault.connectionHash != RemoteTmuxHost.amuxLocal().connectionHash)
        #expect(localDefault.connectionHash != RemoteTmuxHost(destination: "localhost").connectionHash)
    }

    @Test func localDefaultControlInvocationUsesUserTmuxServer() {
        let invocation = RemoteTmuxHost.localDefault()
            .controlProcessInvocation(sessionName: "work", createIfMissing: false)
        #expect(invocation.executablePath == "/usr/bin/script")
        #expect(invocation.arguments.contains("-CC"))
        #expect(invocation.arguments.contains("attach-session"))
        #expect(invocation.arguments.contains("work"))
        #expect(!invocation.arguments.contains("-L"))
        #expect(!invocation.arguments.contains(RemoteTmuxHost.amuxLocalSocketName))
        #expect(!invocation.arguments.contains("-f"))
    }

    /// The `script(1)`-wrapped control surface must resolve tmux to the SAME
    /// executable token the one-shot command surface uses
    /// (``RemoteTmuxHost/localTmuxCommand(arguments:)``), so discovery and attach
    /// can never disagree about which tmux they run on a PATH-only machine. The
    /// expected token is derived from the shared resolver, so this holds whether
    /// tmux resolves to an absolute path (bundled/Homebrew) or `/usr/bin/env`
    /// (bare PATH lookup).
    @Test(arguments: [RemoteTmuxHost.localDefault(), RemoteTmuxHost.amuxLocal()])
    func localControlInvocationResolvesTmuxViaSharedResolver(host: RemoteTmuxHost) {
        let invocation = host.controlProcessInvocation(sessionName: "work", createIfMissing: false)
        let resolvedExecutable = RemoteTmuxHost.localTmuxCommand(arguments: []).executablePath
        #expect(invocation.executablePath == "/usr/bin/script")
        // `script` runs `-q /dev/null <tmux executable> …`; element 2 is the tmux
        // executable token the shared resolver picked.
        #expect(Array(invocation.arguments.prefix(3)) == ["-q", "/dev/null", resolvedExecutable])
    }

    @Test func socketParamsAddressLocalDefaultSeparatelyFromAmuxLocal() {
        #expect(TerminalController.remoteTmuxHost(from: ["local_default": true])?.kind == .localDefault)
        #expect(TerminalController.remoteTmuxHost(from: ["local": true])?.kind == .localAmux)
    }

    @Test func sshConfigAliasPickerSkipsWildcardPatterns() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-config-\(UUID().uuidString)")
        try """
        Host jiun-mbp jiun-mini
          HostName example.test
        Host *
          ForwardAgent no
        Host !blocked *.internal question? percent%token
        Host june-mbp # local alias
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(AppDelegate.amuxSSHConfigHostAliases(configPath: file.path) == [
            "jiun-mbp",
            "jiun-mini",
            "june-mbp",
        ])
    }

    /// True when `a` is immediately followed by `b` in `args` — i.e. an ssh
    /// `-o KEY=VALUE` pair is adjacent, as ssh requires.
    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return true
        }
        return false
    }
}
