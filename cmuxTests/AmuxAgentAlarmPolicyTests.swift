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
        sessionId: String = "session-1",
        lastNotification: String? = nil,
        lastPrompt: String? = nil,
        lastResponse: String? = nil,
        stateEnteredAt: String? = nil
    ) -> CmuxMuxa.MuxaAgent {
        CmuxMuxa.MuxaAgent(
            kind: kind,
            sessionId: sessionId,
            state: state,
            lastPrompt: lastPrompt,
            lastNotification: lastNotification,
            lastResponse: lastResponse,
            stateEnteredAt: stateEnteredAt
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

    func testFinishedBodyPrefersResponseText() {
        let alarm = AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .working,
            to: .idle,
            agent: agent(
                state: .idle,
                lastPrompt: "refactor the parser",
                lastResponse: "Refactored; 12 tests green."
            )
        ))
        XCTAssertEqual(alarm?.body, "Refactored; 12 tests green.")
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

    func testSameStateWaitingRefreshStillAlarms() {
        // muxad's reconciler tick re-emits a waiting agent as a same-state
        // transition. When the original entry edge could not be joined to a
        // workspace (a pane younger than the daemon's inventory), that tick
        // is the only remaining chance to alarm — the policy must not
        // suppress it (per-agent once-per-episode dedupe is the gate's job).
        XCTAssertNotNil(AmuxAgentAlarmPolicy.alarm(for: .init(
            from: .waitingInput,
            to: .waitingInput,
            agent: agent(state: .waitingInput, lastNotification: "still waiting")
        )))
    }

    func testUnknownAgentKindUsesRawWireName() {
        XCTAssertEqual(AmuxAgentAlarmPolicy.displayName(for: .unknown("aider")), "aider")
    }

    // MARK: - Unified display name (finding 7)

    func testDisplayNameIsSourcedFromTheCatalog() {
        // The alarm policy routes display names through the catalog so the
        // notification copy and the launch surfaces never drift. opencode was
        // the drifted case ("opencode" here vs. "OpenCode" in the catalog).
        XCTAssertEqual(AmuxAgentAlarmPolicy.displayName(for: .opencode), "OpenCode")
        XCTAssertEqual(
            AmuxAgentAlarmPolicy.displayName(for: .opencode),
            AmuxAgentCatalog.entry(id: "opencode")?.displayName
        )
        XCTAssertEqual(AmuxAgentAlarmPolicy.displayName(for: .claudeCode), "Claude Code")
        XCTAssertEqual(AmuxAgentAlarmPolicy.displayName(for: .codex), "Codex")
        XCTAssertEqual(AmuxAgentAlarmPolicy.displayName(for: .geminiCli), "Gemini CLI")
        XCTAssertEqual(AmuxAgentCatalog.displayName(for: .unknown("aider")), "aider")
    }

    // MARK: - Gate reconnect behavior (findings 4 & 5)

    @MainActor
    func testGateAlarmsAgainForNewEpisodeAfterReconnect() async {
        let gate = AmuxAgentAlarmGate()
        func waiting(enteredAt: String) -> CmuxMuxa.MuxaTransition {
            .init(
                from: .waitingInput,
                to: .waitingInput,
                agent: agent(state: .waitingInput, stateEnteredAt: enteredAt)
            )
        }
        // Episode 1: blocked, entered at T1. Alarms once; the reconciler-tick
        // refresh of the SAME episode is deduped.
        XCTAssertNotNil(gate.alarm(for: waiting(enteredAt: "2026-07-18T10:00:00Z"), joined: true))
        XCTAssertNil(gate.alarm(for: waiting(enteredAt: "2026-07-18T10:00:00Z"), joined: true))
        // Reconnect: while disconnected the agent churned waiting -> working ->
        // waiting, so the fresh snapshot re-emits waiting with a NEW entry
        // time. Episode memory that survived the reconnect must not swallow the
        // genuinely-new episode.
        XCTAssertNotNil(gate.alarm(for: waiting(enteredAt: "2026-07-18T10:05:00Z"), joined: true))
        XCTAssertNil(gate.alarm(for: waiting(enteredAt: "2026-07-18T10:05:00Z"), joined: true))
    }

    @MainActor
    func testGateForgetsOnlyTheVanishedSessions() async {
        let gate = AmuxAgentAlarmGate()
        func waiting(session: String) -> CmuxMuxa.MuxaTransition {
            .init(
                from: .working,
                to: .waitingInput,
                agent: agent(state: .waitingInput, sessionId: session)
            )
        }
        XCTAssertNotNil(gate.alarm(for: waiting(session: "keep"), joined: true))
        XCTAssertNotNil(gate.alarm(for: waiting(session: "gone"), joined: true))
        XCTAssertNil(gate.alarm(for: waiting(session: "keep"), joined: true), "same episode is deduped")
        // Only "gone" vanished from its daemon's snapshot; forgetting exactly
        // that delta drops its entry (bounding growth) while "keep" stays deduped.
        gate.forget(sessionIds: ["gone"])
        XCTAssertNil(gate.alarm(for: waiting(session: "keep"), joined: true))
        XCTAssertNotNil(gate.alarm(for: waiting(session: "gone"), joined: true))
    }

    @MainActor
    func testSharedGateForgetDoesNotReArmAPeerDaemonsLiveEpisode() async {
        // The gate is shared by the local service and every remote observer.
        // When one daemon reports its own vanished delta, another daemon's
        // still-live episode must survive — otherwise that peer's next
        // reconciler-tick same-state pass re-alarms (a duplicate notification).
        // Regression guard for the shared-gate cross-eviction bug: a per-daemon
        // "keep only my live set" prune would have evicted "remote" here.
        let gate = AmuxAgentAlarmGate()
        func waiting(session: String) -> CmuxMuxa.MuxaTransition {
            .init(
                from: .working,
                to: .waitingInput,
                agent: agent(state: .waitingInput, sessionId: session)
            )
        }
        XCTAssertNotNil(gate.alarm(for: waiting(session: "remote"), joined: true))
        XCTAssertNotNil(gate.alarm(for: waiting(session: "local"), joined: true))
        // The local daemon snapshots: "local" is still live, so its vanished
        // delta is empty — it forgets nothing.
        gate.forget(sessionIds: [])
        // The remote daemon's reconciler tick re-emits "remote" as the same
        // episode: it must stay deduped, not re-alarm.
        XCTAssertNil(
            gate.alarm(for: waiting(session: "remote"), joined: true),
            "a peer daemon's forget must not re-arm this live episode"
        )
    }
}
