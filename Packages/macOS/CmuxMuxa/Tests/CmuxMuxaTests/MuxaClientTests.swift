import Foundation
import Testing
@testable import CmuxMuxa

@Suite("MuxaClient against a fake daemon")
struct MuxaClientTests {
    private static let helloResponse = """
    {"ok":true,"protocol":2,"min_protocol":1,"max_protocol":3,"capabilities":["waiting_choice"]}
    """

    /// Routes hello/snapshot/subscribe request lines to canned responses.
    private static func standardRespond(_ line: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let kind = object["kind"] as? String else {
            return [#"{"ok":false,"protocol":2,"error":"bad request"}"#]
        }
        switch kind {
        case "hello":
            return [helloResponse]
        case "snapshot":
            return ["""
            {"ok":true,"protocol":2,"agents":[
             {"kind":"claude_code","session_id":"s1","pane":"%1","tmux_session":"main","state":"working"},
             {"kind":"codex","session_id":"s2","pane":"%2","tmux_session":"main","state":"waiting_input"}]}
            """.replacingOccurrences(of: "\n", with: "")]
        case "subscribe":
            return [#"{"ok":true,"protocol":2}"#]
        default:
            return [#"{"ok":false,"protocol":2,"error":"unsupported: \#(kind)"}"#]
        }
    }

    @Test("hello handshakes and reports capabilities")
    func helloHandshake() async throws {
        let daemon = try FakeMuxaDaemon(respond: Self.standardRespond)
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let hello = try await client.hello()
        #expect(hello.negotiatedProtocol == 2)
        #expect(hello.supports("waiting_choice"))
        await client.disconnect()
    }

    @Test("snapshot decodes agents over the shared connection")
    func snapshotDecodes() async throws {
        let daemon = try FakeMuxaDaemon(respond: Self.standardRespond)
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let agents = try await client.snapshot()
        #expect(agents.count == 2)
        #expect(agents[0].state == .working)
        #expect(agents[1].state == .waitingInput)
        // Second call reuses the connection (hello is not re-sent; the fake
        // daemon would answer it identically anyway, so assert via behavior:
        // the call simply succeeds).
        let again = try await client.snapshot()
        #expect(again.count == 2)
        await client.disconnect()
    }

    @Test("daemon ok:false surfaces as daemonError")
    func daemonErrorSurfaces() async throws {
        let daemon = try FakeMuxaDaemon { line in
            line.contains("\"hello\"")
                ? [Self.helloResponse]
                : [#"{"ok":false,"protocol":2,"error":"protocol mismatch: server=3 client=2"}"#]
        }
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        await #expect(throws: MuxaClientError.daemonError("protocol mismatch: server=3 client=2")) {
            _ = try await client.snapshot()
        }
    }

    @Test("snapshot skips an undecodable agent row instead of failing wholesale")
    func snapshotSkipsUndecodableRow() async throws {
        // A newer daemon serves one row this client can't decode (missing the
        // required `session_id`); the good rows must still come through.
        let daemon = try FakeMuxaDaemon { line in
            line.contains("\"hello\"")
                ? [Self.helloResponse]
                : ["""
                {"ok":true,"protocol":2,"agents":[
                 {"kind":"claude_code","session_id":"s1","pane":"%1","state":"working"},
                 {"kind":"codex","pane":"%2","state":"waiting_input"},
                 {"kind":"gemini_cli","session_id":"s3","pane":"%3","state":"idle"}]}
                """.replacingOccurrences(of: "\n", with: "")]
        }
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let agents = try await client.snapshot()
        #expect(agents.map(\.sessionId) == ["s1", "s3"])
        await client.disconnect()
    }

    @Test("concurrent first-use calls coalesce onto a single connection")
    func concurrentFirstUseCoalesces() async throws {
        // Eight racing hello() calls must serialize through the client's round-
        // trip lock so only ONE connection is opened (not one per caller).
        let daemon = try FakeMuxaDaemon(respond: Self.standardRespond)
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { (try? await client.hello()) != nil }
            }
            var successes = 0
            for await ok in group where ok { successes += 1 }
            #expect(successes == 8)
        }
        #expect(daemon.totalAccepted == 1)
        await client.disconnect()
    }

    @Test("isReachable returns false when the daemon accepts but never replies")
    func isReachableTimesOutOnWedgedDaemon() async throws {
        // Accept the connection, read the hello, answer nothing — the wedged
        // half-open case. Without the timeout this call would never return.
        let daemon = try FakeMuxaDaemon { _ in [] }
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let reachable = await client.isReachable(timeout: .milliseconds(300))
        #expect(reachable == false)
    }

    @Test("missing socket throws socketUnavailable with the attempted path")
    func missingSocket() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("muxa-nonexistent-\(UUID().uuidString.prefix(8)).sock").path
        let client = MuxaClient(address: MuxaSocketAddress(path: path))
        do {
            _ = try await client.hello()
            Issue.record("expected socketUnavailable")
        } catch let MuxaClientError.socketUnavailable(thrownPath, _) {
            #expect(thrownPath == path)
        }
    }

    @Test("transitions streams pushed lines and finishes on daemon EOF")
    func transitionsStream() async throws {
        // The subscribe pump is detached, so the test must wait until the
        // daemon has seen (and answered) the subscribe request before
        // pushing — pushes written earlier would interleave with the
        // handshake responses.
        let (sawSubscribe, sawSubscribeContinuation) = AsyncStream<Void>.makeStream()
        let daemon = try FakeMuxaDaemon { line in
            if line.contains("\"subscribe\"") { sawSubscribeContinuation.yield() }
            return Self.standardRespond(line)
        }
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let stream = try await client.transitions()
        var subscribeSeen = sawSubscribe.makeAsyncIterator()
        _ = await subscribeSeen.next()

        daemon.push(line: """
        {"from":"working","to":"waiting_input","agent":{"kind":"claude_code","session_id":"s1","pane":"%1","state":"waiting_input"}}
        """.replacingOccurrences(of: "\n", with: ""))
        daemon.push(line: """
        {"from":"waiting_input","to":"working","agent":{"kind":"claude_code","session_id":"s1","pane":"%1","state":"working"}}
        """.replacingOccurrences(of: "\n", with: ""))

        var received: [MuxaTransition] = []
        for try await transition in stream {
            received.append(transition)
            if received.count == 2 { break }
        }
        #expect(received[0].to == .waitingInput)
        #expect(received[0].agent.pane == "%1")
        #expect(received[1].to == .working)
    }

    @Test("transitions skips an undecodable line instead of ending the stream")
    func transitionsSkipsUndecodableLine() async throws {
        let (sawSubscribe, sawSubscribeContinuation) = AsyncStream<Void>.makeStream()
        let daemon = try FakeMuxaDaemon { line in
            if line.contains("\"subscribe\"") { sawSubscribeContinuation.yield() }
            return Self.standardRespond(line)
        }
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let stream = try await client.transitions()
        var subscribeSeen = sawSubscribe.makeAsyncIterator()
        _ = await subscribeSeen.next()

        // A line this client can't decode (missing the required `agent`) must be
        // skipped, not terminate the subscription — the good transition after it
        // still arrives.
        daemon.push(line: #"{"from":"working","to":"waiting_input"}"#)
        daemon.push(line: """
        {"from":"working","to":"waiting_input","agent":{"kind":"claude_code","session_id":"s1","pane":"%1","state":"waiting_input"}}
        """.replacingOccurrences(of: "\n", with: ""))

        var received: [MuxaTransition] = []
        for try await transition in stream {
            received.append(transition)
            if received.count == 1 { break }
        }
        #expect(received.count == 1)
        #expect(received[0].agent.sessionId == "s1")
    }

    @Test("transitions stream ends cleanly when the daemon drops the client")
    func transitionsEndOnDrop() async throws {
        // Wait for the subscribe round trip before dropping: a drop issued
        // before the client is even accepted would miss it entirely and the
        // stream would wait forever.
        let (sawSubscribe, sawSubscribeContinuation) = AsyncStream<Void>.makeStream()
        let daemon = try FakeMuxaDaemon { line in
            if line.contains("\"subscribe\"") { sawSubscribeContinuation.yield() }
            return Self.standardRespond(line)
        }
        defer { daemon.shutdown() }
        let client = MuxaClient(address: MuxaSocketAddress(path: daemon.path))
        let stream = try await client.transitions()
        var subscribeSeen = sawSubscribe.makeAsyncIterator()
        _ = await subscribeSeen.next()
        daemon.dropClients()
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 0)
    }
}
