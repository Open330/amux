import Foundation

/// Async client for the muxad daemon's line-delimited-JSON unix-socket
/// protocol.
///
/// Speaks protocol version ``MuxaClient/pinnedProtocolVersion`` and always
/// opens a connection with a `hello` handshake, so a newer daemon serves this
/// client through its negotiated-downgrade path. Request/response methods
/// (``snapshot()``) share one lazily opened connection; ``transitions()``
/// opens a dedicated connection per call because `subscribe` turns a
/// connection into a one-way stream.
///
/// ```swift
/// let client = MuxaClient()
/// let agents = try await client.snapshot()
/// for try await transition in try await client.transitions() {
///     updateBadge(for: transition.agent)
/// }
/// ```
///
/// Testability: point ``init(address:)`` at a fake daemon bound to a
/// temporary socket path.
public actor MuxaClient {
    /// The protocol version this client pins in every `hello`.
    public static let pinnedProtocolVersion = 2

    /// Informational `name/version` tag sent in `hello` (shows up in muxad logs).
    private static let clientTag = "cmux-amux/0.1"

    private let address: MuxaSocketAddress
    private var shared: MuxaLineConnection?
    /// The last hello result for the live shared connection.
    private var cachedHello: MuxaHello?

    /// Creates a client for the daemon at `address` (defaults to the path a
    /// default-configured muxad binds on this machine).
    public init(address: MuxaSocketAddress = .standard) {
        self.address = address
    }

    /// The daemon's capability handshake for the shared connection,
    /// (re)connecting if needed.
    @discardableResult
    public func hello() async throws -> MuxaHello {
        try await ensureShared()
    }

    /// All currently tracked agents.
    public func snapshot() async throws -> [MuxaAgent] {
        let payload = try await request(kind: "snapshot")
        return try decodeResponse(MuxaSnapshotResponse.self, from: payload).agents
    }

    /// Opens a dedicated subscription connection and streams agent state
    /// transitions until the daemon closes it or the consumer cancels.
    ///
    /// A missing daemon socket throws immediately; handshake/subscribe
    /// failures surface as the stream's terminal error on first iteration.
    /// The stream ends (without error) on daemon EOF; consumers that want
    /// resilience should re-``snapshot()`` and resubscribe, which is also the
    /// documented recovery for a lagged subscriber.
    public func transitions() throws -> AsyncThrowingStream<MuxaTransition, any Error> {
        let connection = try MuxaLineConnection(path: address.path)
        let (stream, continuation) = AsyncThrowingStream<MuxaTransition, any Error>.makeStream()
        // Detached: the pump shares nothing with the actor beyond the
        // Sendable connection and continuation.
        let pump = Task.detached {
            do {
                _ = try await Self.handshake(on: connection)
                try connection.send(line: Self.encodeRequest(kind: "subscribe"))
                guard let ackLine = try await connection.receiveLine() else {
                    throw MuxaClientError.connectionClosed
                }
                try Self.checkEnvelope(ackLine)
                while let line = try await connection.receiveLine() {
                    continuation.yield(try Self.decodeLine(MuxaTransition.self, from: line))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
            connection.close()
        }
        return stream
    }

    /// Drops the shared connection so the next call reconnects.
    public func disconnect() {
        shared?.close()
        shared = nil
        cachedHello = nil
    }

    // MARK: - Shared-connection plumbing

    /// Returns the live shared connection's hello, connecting and handshaking
    /// if there is none.
    @discardableResult
    private func ensureShared() async throws -> MuxaHello {
        if shared != nil, let cachedHello { return cachedHello }
        disconnect()
        let connection = try MuxaLineConnection(path: address.path)
        do {
            let hello = try await Self.handshake(on: connection)
            shared = connection
            cachedHello = hello
            return hello
        } catch {
            connection.close()
            throw error
        }
    }

    private func request(kind: String) async throws -> Data {
        try await ensureShared()
        guard let connection = shared else { throw MuxaClientError.connectionClosed }
        do {
            try connection.send(line: Self.encodeRequest(kind: kind))
            guard let line = try await connection.receiveLine() else {
                throw MuxaClientError.connectionClosed
            }
            return line
        } catch {
            // A failed round trip leaves the connection in an unknown framing
            // state; drop it so the next call starts clean.
            disconnect()
            throw error
        }
    }

    /// Sends `hello` on a fresh connection and decodes the negotiation reply.
    private static func handshake(on connection: MuxaLineConnection) async throws -> MuxaHello {
        try connection.send(line: encodeRequest(kind: "hello", extra: ["client": clientTag]))
        guard let line = try await connection.receiveLine() else {
            throw MuxaClientError.connectionClosed
        }
        try checkEnvelope(line)
        return try decodeLine(MuxaHello.self, from: line)
    }

    // MARK: - Encoding / decoding

    private static func encodeRequest(kind: String, extra: [String: String] = [:]) -> Data {
        var object: [String: Any] = ["protocol": pinnedProtocolVersion, "kind": kind]
        for (key, value) in extra { object[key] = value }
        // Keys and values are JSON-safe by construction (string/int only).
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Throws ``MuxaClientError/daemonError(_:)`` for `ok: false` envelopes.
    private static func checkEnvelope(_ line: Data) throws {
        let envelope = try decodeLine(MuxaResponseEnvelope.self, from: line)
        if envelope.ok != true {
            throw MuxaClientError.daemonError(envelope.error ?? "unknown daemon error")
        }
    }

    private static func decodeLine<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: line)
        } catch {
            throw MuxaClientError.decodingFailed("\(type): \(error)")
        }
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try Self.checkEnvelope(line)
        return try Self.decodeLine(type, from: line)
    }
}

/// The `{ok, error}` framing every daemon response carries.
private struct MuxaResponseEnvelope: Decodable {
    let ok: Bool?
    let error: String?
}

/// Payload shape of a `snapshot` response.
private struct MuxaSnapshotResponse: Decodable {
    let agents: [MuxaAgent]
}
