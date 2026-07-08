import Foundation

/// How cmux reaches the tmux server backing a ``RemoteTmuxHost``.
enum RemoteTmuxHostKind: Sendable, Equatable {
    /// The original remote-mirror path: `ssh -tt <destination> tmux -CC …`,
    /// multiplexed over the host's ControlMaster socket.
    case ssh

    /// The amux local engine (Phase 0 spike): spawn the local `tmux` binary
    /// directly against the dedicated `-L amux` server socket, wrapped in
    /// `script(1)` because a tmux client requires a controlling tty even in
    /// control mode (the SSH path gets one from `-tt`).
    case localAmux
}
