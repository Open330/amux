import Darwin
import Foundation
import os

/// Holds one SSH host's muxad socket forward open.
///
/// Resolves the remote daemon socket path once (a one-shot probe over the
/// host's shared ControlMaster), then establishes an `ssh -N -L` unix-socket
/// forward so a local `MuxaClient` at ``localSocketPath`` reaches the remote
/// muxad. Because the forward multiplexes over the existing master, the
/// *master* ends up owning the listener: the `-N` mux client registers the
/// forwarding and exits immediately (observed OpenSSH mux behavior), so
/// liveness is judged by connecting to the local socket, never by the spawn
/// process. Observe-only and crash-tolerant: the owner's snapshot/subscribe
/// loop calls ``ensureForward()`` before every connect attempt, so a dead
/// forward (master closed, network drop, remote reboot) is re-established on
/// the loop's existing retry cadence.
actor AmuxRemoteMuxaForwarder {
    /// The SSH host whose muxad socket this forward carries.
    let host: RemoteTmuxHost

    /// The local unix-socket path clients connect to (the `-L` bind).
    nonisolated var localSocketPath: String { host.muxaForwardSocketPath }

    /// Lock carve-out: an in-flight spawn must be terminable *synchronously*
    /// from the app-termination path (an actor hop scheduled in
    /// `applicationWillTerminate` may never run). `uncheckedState` because
    /// `Process` isn't `Sendable`; the handle never escapes the lock's short
    /// critical sections.
    private nonisolated let processBox = OSAllocatedUnfairLock<Process?>(uncheckedState: nil)
    private var remoteSocketPath: String?

    /// Creates a forwarder for `host` (kind ``RemoteTmuxHostKind/ssh``).
    init(host: RemoteTmuxHost) {
        self.host = host
    }

    /// Ensures a live forward, establishing one when needed (idempotent).
    ///
    /// A connectable local socket means the master already serves the
    /// forward — re-requesting it would just stack another listener on the
    /// master. Otherwise: probes the remote socket path on first use,
    /// unlinks any stale local socket file, spawns the multiplexed
    /// `ssh -N -L`, and waits briefly for the local end to accept
    /// connections. Throws when the probe cannot resolve a remote path or
    /// the process cannot launch; a forward that is slow to come up is not
    /// an error (the caller's connect simply retries).
    func ensureForward() async throws {
        if Self.canConnect(unixSocketPath: localSocketPath) { return }
        // Re-establishing: a previous spawn handle may linger here. Terminate
        // it before dropping the reference so a stuck ssh (master negotiation
        // hang, network stall) isn't orphaned past app termination.
        terminateStoredProcess()

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
        // Record the handle *before* spawning so a concurrent ``stop()`` (from
        // the synchronous app-termination path) can always find and terminate
        // the ssh we launch. Storing it only after `run()` leaves a window
        // where the just-spawned process is invisible to ``stop()`` and would
        // leak past app termination. Clear it again if the launch throws.
        processBox.withLockUnchecked { $0 = forward }
        do {
            try forward.run()
        } catch {
            processBox.withLockUnchecked { $0 = nil }
            throw error
        }

        // Bounded, cancellable readiness wait: the mux client registers the
        // forward with the master and exits, offering no readiness signal on
        // the success path (only ExitOnForwardFailure on failure), so briefly
        // confirm connectability — same documented pattern as the status
        // service's reconnect poll. Never an error: the caller's connect
        // retries. Process exit is NOT a failure here (see the type doc).
        for _ in 0..<10 {
            if Self.canConnect(unixSocketPath: localSocketPath) { break }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { break }
        }
    }

    /// Tears the forward down: terminates an in-flight spawn and unlinks the
    /// local socket file, which unreaches the master's listener (new
    /// connections need the path; the orphaned listener fd dies with the
    /// master when its ControlPersist window closes after the host's last
    /// mirror detaches).
    ///
    /// `nonisolated` (synchronous, via the process-handle lock) so the
    /// app-termination path and the hub's teardown can both call it without
    /// an actor hop that might never be scheduled.
    nonisolated func stop() {
        terminateStoredProcess()
        try? FileManager.default.removeItem(atPath: localSocketPath)
    }

    /// Terminates any stored spawn handle and clears the box, atomically under
    /// the process lock. Shared by ``stop()`` and the ``ensureForward()``
    /// re-establish path so a lingering ssh is never dropped without being
    /// terminated. Safe when no handle is stored.
    nonisolated func terminateStoredProcess() {
        let process = processBox.withLockUnchecked { handle -> Process? in
            defer { handle = nil }
            return handle
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    #if DEBUG
    /// Test seam: stores `process` as the current spawn handle so unit tests
    /// can exercise the terminate-on-teardown lifecycle without a live SSH host.
    nonisolated func setProcessForTesting(_ process: Process?) {
        processBox.withLockUnchecked { $0 = process }
    }

    /// Test seam: whether a spawn handle is currently stored.
    nonisolated func hasStoredProcessForTesting() -> Bool {
        processBox.withLockUnchecked { $0 != nil }
    }
    #endif

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
