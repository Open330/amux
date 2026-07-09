import Foundation
import Testing
@testable import CmuxMuxa

@Suite("Muxa model decoding")
struct MuxaModelDecodingTests {
    @Test("agent decodes real daemon payload, ignoring unknown fields")
    func agentDecodesLeniently() throws {
        // Field set observed from a live protocol-v3 muxad, including fields
        // this client doesn't model (rate_limit_*).
        let json = """
        {"kind":"claude_code","session_id":"sess-1","pane":"%12","tmux_session":"main",
         "cwd":"/tmp/proj","state":"waiting_choice","last_prompt":"fix bug","last_notification":null,
         "last_response":"done","model":"fable","context_used_pct":34.5,"cost_usd":0.12,
         "rate_limit_5h_pct":10.0,"rate_limit_7d_pct":20.0,
         "started_at":"2026-07-07T12:00:00Z","last_activity_at":"2026-07-07T14:36:14.449918Z",
         "state_entered_at":"2026-07-07T14:00:00Z"}
        """
        let agent = try JSONDecoder().decode(MuxaAgent.self, from: Data(json.utf8))
        #expect(agent.kind == .claudeCode)
        #expect(agent.state == .waitingChoice)
        #expect(agent.state.needsAttention)
        #expect(agent.pane == "%12")
        #expect(agent.tmuxSession == "main")
        #expect(agent.lastResponse == "done")
        #expect(agent.contextUsedPct == 34.5)
        #expect(agent.lastActivityDate != nil)
        #expect(agent.startedDate != nil)
    }

    @Test("unknown state and kind strings decode as .unknown, not a failure")
    func unknownEnumsAreLenient() throws {
        let json = """
        {"kind":"future_agent","session_id":"s","state":"future_state"}
        """
        let agent = try JSONDecoder().decode(MuxaAgent.self, from: Data(json.utf8))
        #expect(agent.kind == .unknown("future_agent"))
        #expect(agent.state == .unknown("future_state"))
        #expect(!agent.state.needsAttention)
    }

    @Test("transition decodes from/to edge plus full agent row")
    func transitionDecodes() throws {
        let json = """
        {"from":"working","to":"waiting_input",
         "agent":{"kind":"codex","session_id":"s2","state":"waiting_input"}}
        """
        let transition = try JSONDecoder().decode(MuxaTransition.self, from: Data(json.utf8))
        #expect(transition.from == .working)
        #expect(transition.to == .waitingInput)
        #expect(transition.agent.kind == .codex)
    }

    @Test("hello decodes negotiated protocol and capabilities")
    func helloDecodes() throws {
        let json = """
        {"ok":true,"protocol":2,"min_protocol":1,"max_protocol":3,
         "capabilities":["waiting_choice","needs_choice","rate_limited"]}
        """
        let hello = try JSONDecoder().decode(MuxaHello.self, from: Data(json.utf8))
        #expect(hello.negotiatedProtocol == 2)
        #expect(hello.maxProtocol == 3)
        #expect(hello.supports("waiting_choice"))
        #expect(!hello.supports("nonexistent"))
    }

    @Test("default socket path prefers XDG_RUNTIME_DIR, falls back to /tmp")
    func socketPathResolution() {
        #expect(MuxaSocketAddress.defaultPath(environment: ["XDG_RUNTIME_DIR": "/run/user/1"], uid: 501)
            == "/run/user/1/muxa.sock")
        #expect(MuxaSocketAddress.defaultPath(environment: [:], uid: 501) == "/tmp/muxa-501.sock")
        #expect(MuxaSocketAddress.defaultPath(environment: ["XDG_RUNTIME_DIR": ""], uid: 7) == "/tmp/muxa-7.sock")
    }

    @Test("timestamp parser accepts fractional and whole-second RFC3339")
    func timestampParsing() {
        #expect(MuxaAgent.parseTimestamp("2026-07-07T14:36:14.449918Z") != nil)
        #expect(MuxaAgent.parseTimestamp("2026-07-07T14:36:14Z") != nil)
        #expect(MuxaAgent.parseTimestamp("not a date") == nil)
    }
}
