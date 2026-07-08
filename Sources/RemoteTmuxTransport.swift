import Foundation

/// The one-shot tmux command surface ``RemoteTmuxController`` runs against a
/// host, independent of how the commands reach the tmux server.
///
/// Two conformers: ``RemoteTmuxSSHTransport`` (commands multiplex over the
/// host's SSH ControlMaster) and ``RemoteTmuxLocalTransport`` (the amux local
/// engine — commands spawn the local tmux binary against the dedicated
/// `-L amux` server). The `-CC` control *stream* is not part of this surface;
/// ``RemoteTmuxControlConnection`` owns it via
/// ``RemoteTmuxHost/controlProcessInvocation(sessionName:createIfMissing:)``.
protocol RemoteTmuxTransport: Actor {
    /// The host this transport talks to (immutable; readable off-actor).
    nonisolated var host: RemoteTmuxHost { get }

    /// Runs `tmux <args…>` against the host's server and returns the captured
    /// result. Does not throw on a non-zero exit — callers classify stderr.
    @discardableResult
    func runTmux(_ args: [String]) async throws -> RemoteTmuxCommandResult

    /// Lists the server's sessions (empty when no server is running).
    func listSessions() async throws -> [RemoteTmuxSession]

    /// Asserts mirroring support, then lists sessions — creating a detached
    /// one first when the server has none and `createIfEmpty` is set.
    func discoverMirrorSessions(createIfEmpty: Bool) async throws -> [RemoteTmuxSession]

    /// Throws ``RemoteTmuxError/unsupportedTmux(detected:)`` when the server
    /// (or, with `checkClientWhenNoServer`, the client binary that would
    /// become one) cannot support live mirroring.
    func assertMinimumTmuxVersion(checkClientWhenNoServer: Bool) async throws

    /// Prepares whatever shared channel the transport multiplexes over.
    /// SSH warms and confirms the ControlMaster; the local transport has no
    /// channel to warm and always reports ready.
    func ensureMasterReady() async throws -> Bool

    /// Tears down the shared channel (no-op for the local transport).
    func shutdownMaster() async
}

extension RemoteTmuxSSHTransport: RemoteTmuxTransport {}
