import Foundation

/// muxad socket forwarding for SSH hosts: the local forward socket path and
/// the remote-side probe that locates (or predicts) the remote daemon socket.
///
/// The agent-observation layer joins muxad rows to mirror workspaces, but
/// muxad listens on a unix socket only. For a remote host the daemon runs on
/// the remote machine, so amux forwards its socket over the host's existing
/// SSH ControlMaster (`ssh -N -L <local>:<remote>`) and points a `MuxaClient`
/// at the local end.
extension RemoteTmuxHost {
    /// The local unix-socket path amux binds as the forwarded end of this
    /// host's remote muxad socket.
    ///
    /// Lives next to the ControlMaster socket under `~/.cmux/ssh/` and uses
    /// the same slug + ``connectionHash`` scheme, so two distinct endpoints
    /// never collide on one forward. The slug is trimmed to the AF_UNIX path
    /// budget exactly like ``controlSocketPath`` (keeping the OpenSSH
    /// transient-suffix reserve for headroom); the hash is never trimmed.
    var muxaForwardSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = "\(home)/.cmux/ssh/muxa-"
        let suffix = "-\(connectionHash).sock"
        let fixedBytes = prefix.utf8.count + suffix.utf8.count + Self.opensshTransientSuffixLength
        let slugBudget = max(0, Self.maxUnixSocketPathLength - fixedBytes)
        return "\(prefix)\(Self.trimmedToUTF8ByteBudget(slug, slugBudget))\(suffix)"
    }

    /// The remote argv that prints the muxad socket path on the remote host.
    ///
    /// Mirrors muxad's own bind rule (`$XDG_RUNTIME_DIR/muxa.sock`, else
    /// `/tmp/muxa-<uid>.sock`): prefers a path where a socket actually exists
    /// right now, and otherwise falls back to the path a default-configured
    /// muxad *would* bind — so the forward can be established before the
    /// daemon starts and begin working the moment it does.
    static var remoteMuxaSocketProbeArgv: [String] {
        let script =
            "if [ -n \"${XDG_RUNTIME_DIR:-}\" ] && [ -S \"$XDG_RUNTIME_DIR/muxa.sock\" ]; then " +
            "printf '%s\\n' \"$XDG_RUNTIME_DIR/muxa.sock\"; " +
            "elif [ -S \"/tmp/muxa-$(id -u).sock\" ]; then " +
            "printf '%s\\n' \"/tmp/muxa-$(id -u).sock\"; " +
            "elif [ -n \"${XDG_RUNTIME_DIR:-}\" ]; then " +
            "printf '%s\\n' \"$XDG_RUNTIME_DIR/muxa.sock\"; " +
            "else printf '%s\\n' \"/tmp/muxa-$(id -u).sock\"; fi"
        return ["/bin/sh", "-c", script]
    }

    /// Parses the probe's stdout into the remote muxad socket path.
    ///
    /// The remote login shell may prepend banner/profile noise, so this takes
    /// the *last* line that looks like an absolute `muxa` socket path rather
    /// than trusting the whole output. `nil` when no line qualifies.
    static func remoteMuxaSocketPath(fromProbeOutput output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && $0.hasSuffix(".sock") && $0.contains("muxa") }
    }

    /// The `ssh` argv (executable first) that holds this host's muxad socket
    /// forward open: `-N` (no remote command) multiplexed over the shared
    /// ControlMaster, `-L <local>:<remote>` unix-socket forwarding, and
    /// `ExitOnForwardFailure` so a failed bind surfaces as process exit
    /// instead of a silent no-op forward.
    func muxaForwardInvocation(
        remoteSocketPath: String,
        sshExecutablePath: String = "/usr/bin/ssh",
        controlPersistSeconds: Int = 180
    ) -> [String] {
        [sshExecutablePath]
            + sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: true)
            + [
                "-N",
                "-o", "ExitOnForwardFailure=yes",
                "-L", "\(muxaForwardSocketPath):\(remoteSocketPath)",
                "--", destination,
            ]
    }
}
