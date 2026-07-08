import Foundation

/// The filesystem address of a muxad unix-domain socket.
///
/// muxad binds `$XDG_RUNTIME_DIR/muxa.sock` when that variable is set and
/// falls back to `/tmp/muxa-<uid>.sock` (the common case on macOS).
public struct MuxaSocketAddress: Sendable, Equatable {
    /// Absolute filesystem path of the socket.
    public let path: String

    /// An address at an explicit path (tests point this at a fake daemon).
    public init(path: String) {
        self.path = path
    }

    /// The address a default-configured muxad binds on this machine.
    public static var standard: MuxaSocketAddress {
        MuxaSocketAddress(path: defaultPath())
    }

    /// Resolves muxad's default socket path from an environment and uid.
    ///
    /// - Parameters:
    ///   - environment: process environment to consult for `XDG_RUNTIME_DIR`
    ///     (injectable for tests).
    ///   - uid: the uid used in the `/tmp` fallback filename.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: uid_t = getuid()
    ) -> String {
        if let runtimeDir = environment["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty {
            return "\(runtimeDir)/muxa.sock"
        }
        return "/tmp/muxa-\(uid).sock"
    }
}
