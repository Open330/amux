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

    /// Bounded lifetime for a one-shot local tmux command. Local commands are
    /// normally subsecond; a command still running after this deadline is treated
    /// as wedged and terminated, so a stuck tmux can never hang the caller (or pin
    /// a cooperative-pool thread) indefinitely. There is no SSH-style
    /// `ConnectTimeout` for a local spawn, so this is the only upper bound.
    private static let commandTimeout: Duration = .seconds(30)

    /// The local host (see ``RemoteTmuxHost/amuxLocal()`` and
    /// ``RemoteTmuxHost/localDefault()``).
    nonisolated let host: RemoteTmuxHost

    init(host: RemoteTmuxHost) {
        self.host = host
    }

    @discardableResult
    func runTmux(_ args: [String]) async throws -> RemoteTmuxCommandResult {
        let tmuxArguments: [String]
        switch host.kind {
        case .localDefault:
            tmuxArguments = args
        case .localAmux:
            tmuxArguments = ["-f", "/dev/null", "-L", RemoteTmuxHost.amuxLocalSocketName] + args
        case .ssh:
            // The transport registry always routes `.ssh` hosts through
            // ``RemoteTmuxSSHTransport``; reaching here means that invariant is
            // broken. Fail loudly instead of silently running the command
            // against the LOCAL default tmux server (no `-L` override), which
            // would target the wrong server entirely.
            assertionFailure(
                "RemoteTmuxLocalTransport received an .ssh host; SSH must use RemoteTmuxSSHTransport"
            )
            throw RemoteTmuxError.commandFailed(
                exitCode: -1,
                stderr: "RemoteTmuxLocalTransport cannot run commands for an SSH host"
            )
        }
        // Resolve tmux through the shared resolver so the one-shot command
        // surface and the control-stream surface agree on which tmux to run
        // (a PATH-only tmux is routed through `/usr/bin/env`).
        let command = RemoteTmuxHost.localTmuxCommand(arguments: tmuxArguments)
        return try await Self.run(
            executablePath: command.executablePath,
            arguments: command.arguments
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
        // Resolve through the shared resolver so a PATH-only tmux is invoked via
        // `/usr/bin/env` here too — otherwise a bare `tmux` executable path can't
        // be exec'd directly and this probe would fail spuriously.
        let clientCommand = RemoteTmuxHost.localTmuxCommand(arguments: ["-V"])
        let client = try await Self.run(
            executablePath: clientCommand.executablePath,
            arguments: clientCommand.arguments
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

    /// Spawns one local process and captures bounded stdout/stderr (each stream
    /// capped at ``maxCapturedOutputBytes`` *during* the read, via
    /// ``drain(fd:maxBytes:)`` — matching the SSH transport's
    /// ``RemoteTmuxSSHTransport/drain(fd:maxBytes:)``).
    ///
    /// Cancellation- and timeout-aware, mirroring the SSH transport: a cancelled
    /// caller (or the ``commandTimeout`` watchdog) terminates the child and closes
    /// its read handles via ``RemoteTmuxProcessCancellation``, so the process is
    /// never orphaned and the drains unblock. The termination handler is installed
    /// before launch (inside the continuation) so a process that exits immediately
    /// can't resume-race the handler.
    private static func run(
        executablePath: String,
        arguments: [String]
    ) async throws -> RemoteTmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Capture only the raw fds (`Int32`, `Sendable`) across the task
        // boundary — never the non-`Sendable` `FileHandle`. The owning `Pipe`s
        // stay alive because `process` retains them until this function returns.
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let outRead = Task.detached { Self.drain(fd: outFD, maxBytes: Self.maxCapturedOutputBytes) }
        let errRead = Task.detached { Self.drain(fd: errFD, maxBytes: Self.maxCapturedOutputBytes) }
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        // Watchdog: terminate a wedged command once ``commandTimeout`` elapses.
        // Cancelled the moment this function returns (normal exit or throw), so it
        // fires only on a genuine overrun; `cancellation.cancel()` is idempotent.
        let timeoutTask = Task {
            try? await Task.sleep(for: Self.commandTimeout)
            if !Task.isCancelled { cancellation.cancel() }
        }
        defer { timeoutTask.cancel() }

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        // The process never started, so the handler will not fire;
                        // resume exactly once here. Use `launchFailed` (not
                        // `commandFailed`) so callers can distinguish a missing /
                        // unlaunchable tmux binary from a genuine non-zero tmux exit.
                        process.terminationHandler = nil
                        continuation.resume(throwing: RemoteTmuxError.launchFailed(error.localizedDescription))
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            outRead.cancel()
            errRead.cancel()
            _ = await outRead.value
            _ = await errRead.value
            throw error
        }

        let outData = await outRead.value
        let errData = await errRead.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Reads a file descriptor to EOF, returning at most `maxBytes`.
    ///
    /// Uses the raw `read(2)` so nothing non-`Sendable` crosses the task
    /// boundary; the owning `Pipe` keeps `fd` open for the duration. The byte
    /// cap is applied DURING the read (the loop keeps draining to EOF but stops
    /// appending past `maxBytes`), so a flooding command can never materialize
    /// its full output in memory before truncation.
    private static func drain(fd: Int32, maxBytes: Int) -> Data {
        var data = Data()
        var remaining = max(0, maxBytes)
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            if Task.isCancelled { break }
            let count = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            if count > 0 {
                if remaining > 0 {
                    let kept = min(count, remaining)
                    data.append(contentsOf: buffer[0..<kept])
                    remaining -= kept
                }
            } else if count == 0 {
                break // EOF
            } else if errno == EINTR {
                continue // interrupted, retry
            } else {
                break // read error (e.g. handle closed on cancel/timeout)
            }
        }
        return data
    }
}
