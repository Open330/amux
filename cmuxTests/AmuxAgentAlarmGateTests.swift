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

    // MARK: - Finished-alarm quiet window

    private func finishedAlarm() -> AmuxAgentAlarm {
        AmuxAgentAlarm(title: "t", body: "b", cooldownKey: "k", cooldownInterval: 20)
    }

    func testFinishedAlarmDeliversAfterQuietWindow() async throws {
        let debounce = AmuxAgentFinishedAlarmDebounce()
        var delivered = 0
        debounce.route(transition: transition(from: .working, to: .idle), alarm: finishedAlarm()) {
            delivered += 1
        }
        XCTAssertEqual(delivered, 0, "finished must be held for the quiet window")
        try await Task.sleep(for: AmuxAgentFinishedAlarmDebounce.quietWindow + .milliseconds(300))
        XCTAssertEqual(delivered, 1)
    }

    func testMilestoneIdleFlashIsSwallowedWhenAgentResumes() async throws {
        let debounce = AmuxAgentFinishedAlarmDebounce()
        var delivered = 0
        debounce.route(transition: transition(from: .working, to: .idle), alarm: finishedAlarm()) {
            delivered += 1
        }
        // The agent resumes within the window: the "finished" was a milestone
        // flash and must never surface.
        debounce.route(transition: transition(from: .idle, to: .working), alarm: nil) {
            XCTFail("a quiet transition never delivers")
        }
        try await Task.sleep(for: AmuxAgentFinishedAlarmDebounce.quietWindow + .milliseconds(300))
        XCTAssertEqual(delivered, 0)
    }

    func testNonFinishedAlarmsDeliverImmediately() {
        let debounce = AmuxAgentFinishedAlarmDebounce()
        var delivered = 0
        debounce.route(transition: transition(from: .working, to: .waitingInput), alarm: finishedAlarm()) {
            delivered += 1
        }
        XCTAssertEqual(delivered, 1, "attention alarms are latency-sensitive and skip the window")
    }

    // MARK: - Working-badge freshness decay

    private func rfc3339(secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    func testStaleWorkingAgentDecaysOutOfTheBadge() {
        let stale = CmuxMuxa.MuxaAgent(
            kind: .claudeCode, sessionId: "s1", state: .working,
            lastActivityAt: rfc3339(secondsAgo: AmuxAgentStatusService.workingStaleAfter + 60)
        )
        XCTAssertNil(
            AmuxAgentStatusService.statusEntry(for: [stale]),
            "a silent working agent past the staleness window shows nothing"
        )
        let fresh = CmuxMuxa.MuxaAgent(
            kind: .claudeCode, sessionId: "s2", state: .working,
            lastActivityAt: rfc3339(secondsAgo: 30)
        )
        XCTAssertNotNil(AmuxAgentStatusService.statusEntry(for: [fresh]))
    }

    func testAttentionStatesNeverDecay() {
        let oldWaiting = CmuxMuxa.MuxaAgent(
            kind: .codex, sessionId: "s3", state: .waitingInput,
            lastActivityAt: rfc3339(secondsAgo: AmuxAgentStatusService.workingStaleAfter * 4)
        )
        let entry = AmuxAgentStatusService.statusEntry(for: [oldWaiting])
        XCTAssertNotNil(entry, "waiting/error stay actionable however old they are")
    }

    func testWorkingWithoutTimestampsDoesNotDecay() {
        let untimestamped = CmuxMuxa.MuxaAgent(kind: .claudeCode, sessionId: "s4", state: .working)
        XCTAssertNotNil(
            AmuxAgentStatusService.statusEntry(for: [untimestamped]),
            "no freshness evidence means no decay — never hide a live agent on missing data"
        )
    }
}

/// The agent catalog (detect/launch manifest behind `amux.agents` /
/// `amux.launch_agent`).
final class AmuxAgentCatalogTests: XCTestCase {
    func testArgvLaunchLineQuotesThePrompt() throws {
        let claude = try XCTUnwrap(AmuxAgentCatalog.entry(id: "claude"))
        XCTAssertEqual(
            claude.launchLine(prompt: "fix the CI's failing test"),
            "claude 'fix the CI'\\''s failing test'"
        )
        XCTAssertEqual(claude.launchLine(prompt: nil), "claude")
    }

    func testFlagLaunchLineUsesTheFlag() throws {
        let opencode = try XCTUnwrap(AmuxAgentCatalog.entry(id: "opencode"))
        XCTAssertEqual(
            opencode.launchLine(prompt: "hello"),
            "opencode --prompt 'hello'"
        )
    }

    func testTypeAfterStartLaunchLineOmitsThePrompt() throws {
        let aider = try XCTUnwrap(AmuxAgentCatalog.entry(id: "aider"))
        XCTAssertEqual(aider.launchLine(prompt: "hello"), "aider")
    }

    func testEntryLookupIsCaseInsensitive() {
        XCTAssertNotNil(AmuxAgentCatalog.entry(id: "Claude"))
        XCTAssertNil(AmuxAgentCatalog.entry(id: "no-such-agent"))
    }

    func testDetectionOutputParsing() {
        let output = """
        claude=/opt/homebrew/bin/claude
        codex=
        gemini=/usr/local/bin/gemini
        """
        let paths = AmuxAgentCatalog.parseDetectionOutput(output)
        XCTAssertEqual(paths["claude"], "/opt/homebrew/bin/claude")
        XCTAssertNil(paths["codex"])
        XCTAssertEqual(paths["gemini"], "/usr/local/bin/gemini")
    }

    func testDetectionRowsUseAliasHits() {
        // cursor resolves through its second alias when the first is absent.
        let rows = AmuxAgentCatalog.detectionRows(paths: ["agent": "/usr/local/bin/agent"])
        let cursor = rows.first { ($0["agent"] as? String) == "cursor" }
        XCTAssertEqual(cursor?["installed"] as? Bool, true)
        XCTAssertEqual(cursor?["path"] as? String, "/usr/local/bin/agent")
        let claude = rows.first { ($0["agent"] as? String) == "claude" }
        XCTAssertEqual(claude?["installed"] as? Bool, false)
    }
}
