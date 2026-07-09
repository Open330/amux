import CmuxMuxa
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AmuxAgentAlarmGateTests: XCTestCase {
    private func transition(
        from: CmuxMuxa.MuxaAgentState,
        to: CmuxMuxa.MuxaAgentState,
        sessionId: String = "gate-1"
    ) -> CmuxMuxa.MuxaTransition {
        .init(
            from: from,
            to: to,
            agent: .init(
                kind: .claudeCode,
                sessionId: sessionId,
                state: to,
                lastPrompt: "do the thing"
            )
        )
    }

    func testAttentionEpisodeAlarmsExactlyOnce() {
        let gate = AmuxAgentAlarmGate()
        // Missed-join entry edge scenario: the first transition the sink
        // sees is a same-state tick refresh — it must alarm...
        XCTAssertNotNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true))
        // ...and every subsequent tick refresh of the same episode is quiet.
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true))
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true))
    }

    func testLeavingAttentionRearmsTheAgent() {
        let gate = AmuxAgentAlarmGate()
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true))
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true))
        // Answering the prompt puts the agent back to work…
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .working), joined: true))
        // …so the next blocked episode alarms again.
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true))
    }

    func testDistinctAttentionStatesEachAlarm() {
        let gate = AmuxAgentAlarmGate()
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true))
        XCTAssertNotNil(gate.alarm(for: transition(from: .waitingInput, to: .error), joined: true))
        XCTAssertNil(gate.alarm(for: transition(from: .error, to: .error), joined: true))
    }

    func testFinishedEdgePassesThroughUngated() {
        let gate = AmuxAgentAlarmGate()
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .idle), joined: true))
        // The finished alarm is edge-gated at the policy level; an idle
        // refresh stays quiet.
        XCTAssertNil(gate.alarm(for: transition(from: .idle, to: .idle), joined: true))
        // A new turn can finish again.
        XCTAssertNil(gate.alarm(for: transition(from: .idle, to: .working), joined: true))
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .idle), joined: true))
    }

    func testUnjoinedAttentionPassDoesNotConsumeTheEpisode() {
        let gate = AmuxAgentAlarmGate()
        // The entry edge arrives before the workspace join resolves (young
        // pane / pre-subscribe snapshot): quiet, and NOT consumed…
        XCTAssertNil(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: false))
        // …so the first joinable pass (a synthetic same-state refresh from
        // applyToWorkspaces) still alarms.
        XCTAssertNotNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true))
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true))
    }

    func testUnjoinedQuietPassStillRearms() {
        let gate = AmuxAgentAlarmGate()
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true))
        // The agent resumes while its join is momentarily unresolvable —
        // memory must still re-arm…
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .working), joined: false))
        // …so the next blocked episode alarms.
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true))
    }

    func testAgentsAreIndependent() {
        let gate = AmuxAgentAlarmGate()
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput, sessionId: "a"), joined: true))
        XCTAssertNotNil(gate.alarm(for: transition(from: .working, to: .waitingInput, sessionId: "b"), joined: true))
        XCTAssertNil(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput, sessionId: "a"), joined: true))
    }
}
