import Darwin
import Foundation
import os

/// Holds one SSH host's muxad socket forward open.
///
/// Resolves the remote daemon socket path once (a one-shot probe over the
/// host's shared ControlMaster), then keeps an `ssh -N -L` unix-socket
/// forward process alive so a local `MuxaClient` at ``localSocketPath``
/// reaches the remote muxad. Observe-only and crash-tolerant: the owner's
/// snapshot/subscribe loop calls ``ensureForward()`` before every connect
/// attempt, so a dead forward (master closed, network drop, remote reboot)
/// is respawned on the loop's existing retry cadence.
actor AmuxRemoteMuxaForwarder {
    /// The SSH host whose muxad socket this forward carries.
    let host: RemoteTmuxHost

    /// The local unix-socket path clients connect to (the `-L` bind).
    nonisolated var localSocketPath: String { host.muxaForwardSocketPath }

    /// Lock carve-out: the forward process handle must be terminable
    /// *synchronously* from the app-termination path (an actor hop scheduled
    /// in `applicationWillTerminate` may never run, orphaning an `ssh -N`
    /// that pins the ControlMaster past its ControlPersist window).
    /// `uncheckedState` because `Process` isn't `Sendable`; the handle never
    /// escapes the lock's short critical sections.
    private nonisolated let processBox = OSAllocatedUnfairLock<Process?>(uncheckedState: nil)
    private var remoteSocketPath: String?

    /// Creates a forwarder for `host` (kind ``RemoteTmuxHostKind/ssh``).
    init(host: RemoteTmuxHost) {
        self.host = host
    }

    /// Ensures a live forward process, spawning one when needed (idempotent).
    ///
    /// Probes the remote socket path on first use, unlinks any stale local
    /// socket file, spawns the multiplexed `ssh -N -L`, and waits briefly for
    /// the local end to accept connections. Throws when the probe cannot
    /// resolve a remote path or the process cannot launch; a forward that is
    /// slow to come up is not an error (the caller's connect simply retries).
    func ensureForward() async throws {
        if processBox.withLockUnchecked({ $0?.isRunning == true }) { return }
        processBox.withLockUnchecked { $0 = nil }

        try host.ensureControlSocketDirectory()
        let remotePath: String
        if let remoteSocketPath {
            remotePath = remoteSocketPath
        } else {
            let probe = try await RemoteTmuxSSHTransport.runProcess(
                executable: "/usr/bin/ssh",
                arguments: host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
                    + ["--", host.destination]
                    + [RemoteTmuxHost.remoteMuxaSocketProbeArgv
                        .map(RemoteTmuxHost.shellSingleQuoted)
                        .joined(separator: " ")]
            )
            guard probe.exitCode == 0,
                  let resolved = RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: probe.stdout)
            else {
                throw RemoteTmuxError.commandFailed(exitCode: probe.exitCode, stderr: probe.stderr)
            }
            remoteSocketPath = resolved
            remotePath = resolved
        }

        // The previous forward's bind lingers as a dead socket file; ssh
        // refuses to bind over it, so clear our own path before spawning.
        try? FileManager.default.removeItem(atPath: localSocketPath)

        let argv = host.muxaForwardInvocation(remoteSocketPath: remotePath)
        let forward = Process()
        forward.executableURL = URL(fileURLWithPath: argv[0])
        forward.arguments = Array(argv.dropFirst())
        forward.standardInput = FileHandle.nullDevice
        forward.standardOutput = FileHandle.nullDevice
        forward.standardError = FileHandle.nullDevice
        try forward.run()
        processBox.withLockUnchecked { $0 = forward }

        // Bounded, cancellable readiness wait: ssh binds the local socket a
        // few ms after launch and offers no readiness signal on the success
        // path (only ExitOnForwardFailure on failure), so briefly confirm
        // connectability — same documented pattern as the status service's
        // reconnect poll. Never an error: the caller's connect retries.
        for _ in 0..<10 {
            if !forward.isRunning { break }
            if Self.canConnect(unixSocketPath: localSocketPath) { break }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { break }
        }
    }

    /// Terminates the forward process and removes the local socket file.
    ///
    /// `nonisolated` (synchronous, via the process-handle lock) so the
    /// app-termination path and the hub's teardown can both call it without
    /// an actor hop that might never be scheduled.
    nonisolated func stop() {
        let process = processBox.withLockUnchecked { handle -> Process? in
            defer { handle = nil }
            return handle
        }
        if let process, process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(atPath: localSocketPath)
    }

    /// Whether a unix socket at `path` currently accepts a connection — the
    /// forward-readiness check (a bind exists *and* ssh is serving it).
    static func canConnect(unixSocketPath path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= capacity else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        return result == 0
    }
}
