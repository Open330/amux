import CmuxMuxa
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AmuxAgentAlarmGateTests {
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

    @Test func attentionEpisodeAlarmsExactlyOnce() {
        let gate = AmuxAgentAlarmGate()
        // Missed-join entry edge scenario: the first transition the sink
        // sees is a same-state tick refresh - it must alarm.
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true) != nil)
        // Every subsequent tick refresh of the same episode is quiet.
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true) == nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true) == nil)
    }

    @Test func leavingAttentionRearmsTheAgent() {
        let gate = AmuxAgentAlarmGate()
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true) == nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .working), joined: true) == nil)
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true) != nil)
    }

    @Test func distinctAttentionStatesEachAlarm() {
        let gate = AmuxAgentAlarmGate()
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .error), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .error, to: .error), joined: true) == nil)
    }

    @Test func finishedEdgePassesThroughUngated() {
        let gate = AmuxAgentAlarmGate()
        #expect(gate.alarm(for: transition(from: .working, to: .idle), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .idle, to: .idle), joined: true) == nil)
        #expect(gate.alarm(for: transition(from: .idle, to: .working), joined: true) == nil)
        #expect(gate.alarm(for: transition(from: .working, to: .idle), joined: true) != nil)
    }

    @Test func unjoinedAttentionPassDoesNotConsumeTheEpisode() {
        let gate = AmuxAgentAlarmGate()
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: false) == nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput), joined: true) == nil)
    }

    @Test func unjoinedQuietPassStillRearms() {
        let gate = AmuxAgentAlarmGate()
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .working), joined: false) == nil)
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput), joined: true) != nil)
    }

    @Test func agentsAreIndependent() {
        let gate = AmuxAgentAlarmGate()
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput, sessionId: "a"), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .working, to: .waitingInput, sessionId: "b"), joined: true) != nil)
        #expect(gate.alarm(for: transition(from: .waitingInput, to: .waitingInput, sessionId: "a"), joined: true) == nil)
    }

    // MARK: - Finished-alarm quiet window

    private func finishedAlarm() -> AmuxAgentAlarm {
        AmuxAgentAlarm(title: "t", body: "b", cooldownKey: "k", cooldownInterval: 20)
    }

    @Test func finishedAlarmDeliversAfterQuietWindow() async throws {
        let debounce = AmuxAgentFinishedAlarmDebounce()
        var delivered = 0
        debounce.route(transition: transition(from: .working, to: .idle), alarm: finishedAlarm()) {
            delivered += 1
        }
        #expect(delivered == 0, "finished must be held for the quiet window")
        try await Task.sleep(for: AmuxAgentFinishedAlarmDebounce.quietWindow + .milliseconds(300))
        #expect(delivered == 1)
    }

    @Test func milestoneIdleFlashIsSwallowedWhenAgentResumes() async throws {
        let debounce = AmuxAgentFinishedAlarmDebounce()
        var delivered = 0
        debounce.route(transition: transition(from: .working, to: .idle), alarm: finishedAlarm()) {
            delivered += 1
        }
        debounce.route(transition: transition(from: .idle, to: .working), alarm: nil) {
            Issue.record("a quiet transition never delivers")
        }
        try await Task.sleep(for: AmuxAgentFinishedAlarmDebounce.quietWindow + .milliseconds(300))
        #expect(delivered == 0)
    }

    @Test func nonFinishedAlarmsDeliverImmediately() {
        let debounce = AmuxAgentFinishedAlarmDebounce()
        var delivered = 0
        debounce.route(transition: transition(from: .working, to: .waitingInput), alarm: finishedAlarm()) {
            delivered += 1
        }
        #expect(delivered == 1, "attention alarms are latency-sensitive and skip the window")
    }

    // MARK: - Working-badge freshness decay

    private func rfc3339(secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    @Test func staleWorkingAgentDecaysOutOfTheBadge() {
        let stale = CmuxMuxa.MuxaAgent(
            kind: .claudeCode, sessionId: "s1", state: .working,
            lastActivityAt: rfc3339(secondsAgo: AmuxAgentStatusService.workingStaleAfter + 60)
        )
        #expect(
            AmuxAgentStatusService.statusEntry(for: [stale]) == nil,
            "a silent working agent past the staleness window shows nothing"
        )
        let fresh = CmuxMuxa.MuxaAgent(
            kind: .claudeCode, sessionId: "s2", state: .working,
            lastActivityAt: rfc3339(secondsAgo: 30)
        )
        #expect(AmuxAgentStatusService.statusEntry(for: [fresh]) != nil)
    }

    @Test func attentionStatesNeverDecay() {
        let oldWaiting = CmuxMuxa.MuxaAgent(
            kind: .codex, sessionId: "s3", state: .waitingInput,
            lastActivityAt: rfc3339(secondsAgo: AmuxAgentStatusService.workingStaleAfter * 4)
        )
        #expect(
            AmuxAgentStatusService.statusEntry(for: [oldWaiting]) != nil,
            "waiting/error stay actionable however old they are"
        )
    }

    @Test func workingWithoutTimestampsDoesNotDecay() {
        let untimestamped = CmuxMuxa.MuxaAgent(kind: .claudeCode, sessionId: "s4", state: .working)
        #expect(
            AmuxAgentStatusService.statusEntry(for: [untimestamped]) != nil,
            "no freshness evidence means no decay - never hide a live agent on missing data"
        )
    }
}

/// The agent catalog behind `amux.agents` and `amux.launch_agent`.
@Suite
struct AmuxAgentCatalogTests {
    @Test func argvLaunchLineQuotesThePrompt() throws {
        let claude = try #require(AmuxAgentCatalog.entry(id: "claude"))
        #expect(
            claude.launchLine(prompt: "fix the CI's failing test")
                == "claude 'fix the CI'\\''s failing test'"
        )
        #expect(claude.launchLine(prompt: nil) == "claude")
    }

    @Test func flagLaunchLinesUseInteractiveAgentFlags() throws {
        let opencode = try #require(AmuxAgentCatalog.entry(id: "opencode"))
        #expect(opencode.launchLine(prompt: "hello") == "opencode --prompt 'hello'")

        let gemini = try #require(AmuxAgentCatalog.entry(id: "gemini"))
        #expect(gemini.launchLine(prompt: "hello") == "gemini --prompt-interactive 'hello'")
    }

    @Test func stdinAfterStartAgentsDoNotPutThePromptInArgv() throws {
        for id in ["aider", "grok", "qwen"] {
            let entry = try #require(AmuxAgentCatalog.entry(id: id))
            #expect(entry.launchLine(prompt: "hello") == entry.detectCommands[0], "\(id)")
        }
    }

    @Test func entryLookupIsCaseInsensitive() {
        #expect(AmuxAgentCatalog.entry(id: "Claude") != nil)
        #expect(AmuxAgentCatalog.entry(id: "no-such-agent") == nil)
    }

    @Test func detectionOutputParsing() {
        let output = """
        claude=/opt/homebrew/bin/claude
        codex=
        gemini=/usr/local/bin/gemini
        """
        let paths = AmuxAgentCatalog.parseDetectionOutput(output)
        #expect(paths["claude"] == "/opt/homebrew/bin/claude")
        #expect(paths["codex"] == nil)
        #expect(paths["gemini"] == "/usr/local/bin/gemini")
    }

    @Test func genericAgentCommandDoesNotImpersonateCursor() throws {
        let cursorEntry = try #require(AmuxAgentCatalog.entry(id: "cursor"))
        #expect(cursorEntry.detectCommands == ["cursor-agent"])

        let rows = AmuxAgentCatalog.detectionRows(paths: ["agent": "/usr/local/bin/agent"])
        let cursor = try #require(rows.first { ($0["agent"] as? String) == "cursor" })
        #expect(cursor["installed"] as? Bool == false)
    }

    @Test func launchUsesTheDetectedAliasAbsolutePath() throws {
        let vibe = try #require(AmuxAgentCatalog.entry(id: "mistral-vibe"))
        let paths = ["mistral-vibe": "/opt/agent tools/mistral-vibe"]
        let executable = try #require(vibe.resolvedExecutable(in: paths))
        #expect(
            vibe.launchLine(prompt: "hello", executable: executable)
                == "'/opt/agent tools/mistral-vibe'"
        )
    }

    @Test func launchArgumentsPrecedePromptInjection() throws {
        let commandCode = try #require(AmuxAgentCatalog.entry(id: "command-code"))
        #expect(
            commandCode.launchLine(prompt: "review this")
                == "command-code --trust 'review this'"
        )
        let kiro = try #require(AmuxAgentCatalog.entry(id: "kiro"))
        #expect(kiro.launchLine(prompt: "review this") == "kiro-cli chat --tui")
    }

    @Test func remoteDetectionPassesTheProbeAsData() {
        let arguments = AmuxAgentCatalog.remoteDetectionArguments()
        #expect(arguments.prefix(2) == ["/bin/sh", "-c"])
        #expect(arguments[2].contains("\"$1\""))
        #expect(arguments[4] == AmuxAgentCatalog.detectionScript())
    }

    @Test func paneReadinessUsesForegroundEvents() async {
        let (states, continuation) = AsyncStream<RemoteTmuxPaneForegroundState>.makeStream()
        continuation.yield(.init(rawValue: "0|zsh"))
        Task {
            try? await Task.sleep(for: .milliseconds(5))
            continuation.yield(.init(rawValue: "1|claude"))
            continuation.finish()
        }
        #expect(
            await TerminalController.waitForAgentPaneReady(
                states,
                timeout: .milliseconds(100)
            )
        )
    }

    @Test func paneReadinessHasABoundedDeadline() async {
        let (states, continuation) = AsyncStream<RemoteTmuxPaneForegroundState>.makeStream()
        continuation.yield(.init(rawValue: "0|zsh"))
        #expect(
            await !TerminalController.waitForAgentPaneReady(
                states,
                timeout: .milliseconds(10)
            )
        )
        continuation.finish()
    }
}

@Suite
struct AmuxAgentStatusPayloadTests {
    @Test func stablePayloadPreservesEveryMuxaObservationField() {
        let agent = CmuxMuxa.MuxaAgent(
            kind: .codex,
            sessionId: "session-1",
            pane: "%7",
            tmuxSession: "review",
            cwd: "/repo",
            state: .waitingChoice,
            lastPrompt: "review",
            lastNotification: "choose an option",
            lastResponse: "I need a decision",
            model: "gpt-5",
            contextUsedPct: 42.5,
            costUsd: 1.25,
            startedAt: "2026-07-10T01:00:00Z",
            lastActivityAt: "2026-07-10T01:02:00Z",
            stateEnteredAt: "2026-07-10T01:01:00Z"
        )

        let payload = TerminalController.amuxAgentPayload(agent)

        #expect(payload["kind"] as? String == "codex")
        #expect(payload["session_id"] as? String == "session-1")
        #expect(payload["pane"] as? String == "%7")
        #expect(payload["tmux_session"] as? String == "review")
        #expect(payload["cwd"] as? String == "/repo")
        #expect(payload["state"] as? String == "waiting_choice")
        #expect(payload["last_prompt"] as? String == "review")
        #expect(payload["last_notification"] as? String == "choose an option")
        #expect(payload["last_response"] as? String == "I need a decision")
        #expect(payload["model"] as? String == "gpt-5")
        #expect(payload["context_used_pct"] as? Double == 42.5)
        #expect(payload["cost_usd"] as? Double == 1.25)
        #expect(payload["started_at"] as? String == "2026-07-10T01:00:00Z")
        #expect(payload["last_activity_at"] as? String == "2026-07-10T01:02:00Z")
        #expect(payload["state_entered_at"] as? String == "2026-07-10T01:01:00Z")
    }
}
