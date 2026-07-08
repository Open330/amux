import Foundation

/// Errors thrown by ``MuxaClient``.
public enum MuxaClientError: Error, Sendable, Equatable {
    /// The daemon socket could not be opened (muxad not running, or the path
    /// is wrong). Carries the attempted path and the POSIX errno.
    case socketUnavailable(path: String, errno: Int32)
    /// The connection closed before a complete response arrived.
    case connectionClosed
    /// The daemon answered `ok: false`; carries its `error` message.
    case daemonError(String)
    /// A response line was not valid JSON for the expected shape; carries a
    /// short description of what failed to decode.
    case decodingFailed(String)
}
