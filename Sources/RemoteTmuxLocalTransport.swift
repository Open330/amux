import Foundation

/// ``RemoteTmuxTransport`` for local tmux endpoints: every command spawns the
/// local tmux binary. The amux engine uses the dedicated, config-isolated server
/// (`tmux -f /dev/null -L amux <args…>`); localhost sync uses the user's default
/// tmux server unchanged.
///
/// There is no shared channel to warm or tear down (each command is its own
/// short-lived process), so ``ensureMasterReady()`` always reports ready and
/// ``shutdownMaster()`` is a no-op — the tmux server itself deliberately
/// outlives the app (detach-by-default).
///
/// Modeled as an `actor` to match the transport protocol's isolation; the
/// stderr classifiers are shared with the SSH transport so both paths treat
/// "no server running" identically.
actor RemoteTmuxLocalTransport: RemoteTmuxTransport {
    private static let maxCapturedOutputBytes = 1_048_576

    /// The local host (see ``RemoteTmuxHost/amuxLocal()`` and
    /// ``RemoteTmuxHost/localDefault()``).
    nonisolated let host: RemoteTmuxHost

    init(host: RemoteTmuxHost) {
        self.host = host
    }

    @discardableResult
    func runTmux(_ args: [String]) async throws -> RemoteTmuxCommandResult {
        let tmuxPath = RemoteTmuxHost.localTmuxExecutablePath()
        let executablePath: String
        let arguments: [String]
        let tmuxArguments: [String]
        switch host.kind {
        case .localDefault:
            tmuxArguments = args
        case .localAmux:
            tmuxArguments = ["-f", "/dev/null", "-L", RemoteTmuxHost.amuxLocalSocketName] + args
        case .ssh:
            tmuxArguments = args
        }
        if tmuxPath.contains("/") {
            executablePath = tmuxPath
            arguments = tmuxArguments
        } else {
            executablePath = "/usr/bin/env"
            arguments = [tmuxPath] + tmuxArguments
        }
        return try await Self.run(
            executablePath: executablePath,
            arguments: arguments
        )
    }

    func listSessions() async throws -> [RemoteTmuxSession] {
        let result = try await runTmux([
            "list-sessions", "-F", RemoteTmuxSessionListParser.formatString,
        ])
        if !result.succeeded {
            if RemoteTmuxSSHTransport.indicatesNoServer(result.stderr) { return [] }
            throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return RemoteTmuxSessionListParser.parse(result.stdout)
    }

    func discoverMirrorSessions(createIfEmpty: Bool) async throws -> [RemoteTmuxSession] {
        try await assertMinimumTmuxVersion(checkClientWhenNoServer: createIfEmpty)
        var sessions = try await listSessions()
        if sessions.isEmpty, createIfEmpty {
            _ = try? await runTmux(["new-session", "-d"])
            sessions = try await listSessions()
        }
        return sessions
    }

    func assertMinimumTmuxVersion(checkClientWhenNoServer: Bool) async throws {
        let probe = try await runTmux(["display-message", "-p", "#{version}"])
        if probe.succeeded {
            guard let version = RemoteTmuxVersion.parseServerFormat(probe.stdout) else {
                // Local dev/distro builds with unparseable versions are new
                // enough in practice; unlike SSH there is no old fleet to
                // guard against, so allow instead of probing further.
                return
            }
            if !version.meetsMinimum {
                throw RemoteTmuxError.unsupportedTmux(detected: version.displayString)
            }
            return
        }
        guard RemoteTmuxSSHTransport.indicatesNoServer(probe.stderr) else {
            throw RemoteTmuxError.commandFailed(exitCode: probe.exitCode, stderr: probe.stderr)
        }
        guard checkClientWhenNoServer else { return }
        let client = try await Self.run(
            executablePath: RemoteTmuxHost.localTmuxExecutablePath(),
            arguments: ["-V"]
        )
        guard client.succeeded else {
            throw RemoteTmuxError.commandFailed(exitCode: client.exitCode, stderr: client.stderr)
        }
        if let version = RemoteTmuxVersion.parse(client.stdout), !version.meetsMinimum {
            throw RemoteTmuxError.unsupportedTmux(detected: version.displayString)
        }
    }

    func ensureMasterReady() async throws -> Bool { true }

    func shutdownMaster() async {}

    /// Spawns one local process and captures its output (both streams capped
    /// at ``maxCapturedOutputBytes``, matching the SSH transport's cap).
    private static func run(
        executablePath: String,
        arguments: [String]
    ) async throws -> RemoteTmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw RemoteTmuxError.commandFailed(exitCode: -1, stderr: "\(error)")
        }

        // Drain both pipes and wait for exit, all off the cooperative pool
        // (the reads and waitUntilExit block). A detached wait avoids the
        // set-terminationHandler-after-exit race.
        async let stdoutData = Self.drain(outPipe.fileHandleForReading)
        async let stderrData = Self.drain(errPipe.fileHandleForReading)
        let exitCode = await Task.detached { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: await stdoutData.prefix(maxCapturedOutputBytes), as: UTF8.self),
            stderr: String(decoding: await stderrData.prefix(maxCapturedOutputBytes), as: UTF8.self)
        )
    }

    /// Reads a pipe to EOF on a detached task keyed by the raw fd (the
    /// `FileHandle` read is blocking and must stay off the caller's executor).
    private static func drain(_ handle: FileHandle) async -> Data {
        let fd = handle.fileDescriptor
        return await Task.detached {
            var collected = Data()
            var scratch = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &scratch, scratch.count)
                if count > 0 {
                    collected.append(contentsOf: scratch[0..<count])
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            return collected
        }.value
    }
}
