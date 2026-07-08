/// The daemon's reply to a `hello` capability handshake.
///
/// `hello` opts the connection into negotiated-protocol mode: the server
/// downgrades enum variants the pinned version doesn't understand, so a
/// v2-pinned client keeps working against a v3 daemon. Feature-gate on
/// ``capabilities`` tags, not protocol integers.
public struct MuxaHello: Sendable, Equatable, Codable {
    /// The protocol version the server agreed to speak (echoes the client's
    /// requested version).
    public let negotiatedProtocol: Int
    /// The lowest protocol version the server can serve.
    public let minProtocol: Int
    /// The highest protocol version the server can serve.
    public let maxProtocol: Int
    /// Semver-additive feature tags (e.g. `waiting_choice`, `rate_limited`).
    public let capabilities: Set<String>

    enum CodingKeys: String, CodingKey {
        case negotiatedProtocol = "protocol"
        case minProtocol = "min_protocol"
        case maxProtocol = "max_protocol"
        case capabilities
    }

    /// Whether the daemon advertises `capability` (e.g. `"waiting_choice"`).
    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    public init(negotiatedProtocol: Int, minProtocol: Int, maxProtocol: Int, capabilities: Set<String>) {
        self.negotiatedProtocol = negotiatedProtocol
        self.minProtocol = minProtocol
        self.maxProtocol = maxProtocol
        self.capabilities = capabilities
    }
}
