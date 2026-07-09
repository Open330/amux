import CmuxMuxa
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmuxAgentAlarmPolicyTests: XCTestCase {
    private func agent(
        state: CmuxMuxa.MuxaAgentState,
        kind: CmuxMuxa.MuxaAgentKind = .claudeCode,
        lastNotification: String? = nil,
        lastPrompt: String? = nil
    ) -> CmuxMuxa.MuxaAgent {
        CmuxMuxa.MuxaAgent(
            kind: kind,
            sessionId: "session-1",
            state: state,
            lastPrompt: lastPrompt,
            lastNotification: lastNotification
        )
    }

    func testEnteringWaitingInputAlarms() {
        let alarm = AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .waitingInput,
            agent: agent(state: .waitingInput, lastNotification: "Permission needed")
        ))
        XCTAssertNotNil(alarm)
        XCTAssertTrue(alarm?.title.contains("Claude Code") == true)
        XCTAssertEqual(alarm?.body, "Permission needed")
        XCTAssertEqual(alarm?.cooldownKey, "amux.agent.session-1.waiting_input")
    }

    func testEnteringWaitingChoiceAlarms() {
        XCTAssertNotNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .waitingChoice,
            agent: agent(state: .waitingChoice)
        )))
    }

    func testEnteringErrorAlarms() {
        XCTAssertNotNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .error,
            agent: agent(state: .error)
        )))
    }

    func testWorkingToIdleAlarmsAsFinished() {
        let alarm = AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .idle,
            agent: agent(state: .idle, lastPrompt: "refactor the parser")
        ))
        XCTAssertNotNil(alarm)
        XCTAssertEqual(alarm?.body, "refactor the parser")
    }

    func testFinishedBodyPrefersPromptOverStaleNotification() {
        let alarm = AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .idle,
            agent: agent(
                state: .idle,
                lastNotification: "Claude needs your permission",
                lastPrompt: "refactor the parser"
            )
        ))
        XCTAssertEqual(alarm?.body, "refactor the parser")
    }

    func testStartingToIdleIsQuiet() {
        XCTAssertNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .starting,
            to: .idle,
            agent: agent(state: .idle)
        )))
    }

    func testSameStateRefreshIsQuiet() {
        XCTAssertNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .waitingInput,
            to: .waitingInput,
            agent: agent(state: .waitingInput)
        )))
    }

    func testWorkingAndStoppedAreQuiet() {
        XCTAssertNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .idle,
            to: .working,
            agent: agent(state: .working)
        )))
        XCTAssertNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .stopped,
            agent: agent(state: .stopped)
        )))
    }

    func testUnknownAgentKindUsesRawWireName() {
        XCTAssertEqual(AmuxAgentAlarmPolicy.displayName(for: .unknown("aider")), "aider")
    }
}
