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

    // MARK: Round-trip serialization
    //
    // Actor isolation does not hold across `await`, so without a mutex two
    // concurrent first-use calls would each pass the `shared == nil` check and
    // open a duplicate connection, and once a second request *kind* exists two
    // in-flight round-trips would pipeline `send`/`receiveLine` on one
    // connection and could be cross-delivered each other's response. This tiny
    // FIFO async lock makes every shared-connection round trip (handshake or
    // request) mutually exclusive. `transitions()` uses a dedicated connection
    // and is intentionally not gated here.
    private var lockHeld = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireLock() async {
        if !lockHeld {
            lockHeld = true
            return
        }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func releaseLock() {
        if lockWaiters.isEmpty {
            lockHeld = false
        } else {
            lockWaiters.removeFirst().resume()
        }
    }

    /// Creates a client for the daemon at `address` (defaults to the path a
    /// default-configured muxad binds on this machine).
    public init(address: MuxaSocketAddress = .standard) {
        self.address = address
    }

    /// The daemon's capability handshake for the shared connection,
    /// (re)connecting if needed.
    @discardableResult
    public func hello() async throws -> MuxaHello {
        await acquireLock()
        defer { releaseLock() }
        return try await ensureShared()
    }

    /// Whether a muxad is answering on the socket right now (a `hello`
    /// round trip succeeds within `timeout`). Used to decide whether amux
    /// should manage its own daemon or defer to an already-running one. Never
    /// throws — a missing daemon / any failure / a timeout is simply `false`.
    ///
    /// The timeout matters: a daemon that accepts the connection but never
    /// answers (crashed mid-accept, wedged, or a stale forwarded socket)
    /// would otherwise suspend this call — and the startup path that awaits
    /// it — forever.
    public func isReachable(timeout: Duration = .seconds(3)) async -> Bool {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in _ = try await hello() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MuxaClientError.connectionClosed
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            return true
        } catch {
            // Timed out or failed: drop any half-open connection so a later
            // call starts clean, and report the daemon as absent.
            disconnect()
            return false
        }
    }

    /// All currently tracked agents.
    public func snapshot() async throws -> [MuxaAgent] {
        await acquireLock()
        defer { releaseLock() }
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
        // Bounded buffer: a slow consumer drops the oldest transitions rather
        // than letting `yield` buffer without limit — a lagged subscriber is
        // expected to re-`snapshot()` and resubscribe to reconcile anyway.
        let (stream, continuation) = AsyncThrowingStream<MuxaTransition, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
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
///
/// The `agents` array is decoded leniently: a single row a newer daemon
/// serves in a shape this client can't decode (a missing/renamed required
/// field) is skipped rather than failing the whole snapshot — the same
/// forward-compatibility contract the enum `.unknown` cases provide.
private struct MuxaSnapshotResponse: Decodable {
    let agents: [MuxaAgent]

    enum CodingKeys: String, CodingKey { case agents }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unkeyed = try container.nestedUnkeyedContainer(forKey: .agents)
        var decoded: [MuxaAgent] = []
        if let count = unkeyed.count { decoded.reserveCapacity(count) }
        while !unkeyed.isAtEnd {
            // Decoding the always-succeeding wrapper consumes exactly one
            // element, so a bad row advances the index instead of wedging.
            let element = try unkeyed.decode(LenientElement<MuxaAgent>.self)
            if let agent = element.value { decoded.append(agent) }
        }
        self.agents = decoded
    }
}

/// Decodes `Wrapped` if possible, otherwise yields `nil` while still
/// consuming its slot — so an unkeyed container can skip undecodable rows.
private struct LenientElement<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
