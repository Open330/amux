import CmuxMuxa
import Foundation

/// Stateful once-per-episode dedupe over ``AmuxAgentAlarmPolicy``.
///
/// The policy alarms on every transition *into or within* an attention state
/// (muxad's reconciler tick re-emits waiting agents as same-state
/// transitions, and for a pane younger than the daemon's inventory that tick
/// is the first transition the app can join to a workspace), so this gate
/// remembers the last attention state it delivered per agent and lets each
/// attention episode through exactly once. Leaving the attention state (or
/// stopping) re-arms the agent; the finished edge is inherently one-shot at
/// the policy level and passes through untouched.
///
/// Consult the gate only for transitions that resolved to a workspace: a
/// transition dropped for lack of a join must not consume the episode.
@MainActor
final class AmuxAgentAlarmGate {
    /// One attention episode, the dedupe unit. Keyed on both the state and
    /// *when* the agent entered it: an agent that leaves and re-enters an
    /// attention state — possibly entirely while the app was disconnected —
    /// advances ``MuxaAgent/stateEnteredAt``, so a genuinely-new episode
    /// alarms again instead of being swallowed by memory that survived the
    /// reconnect. A `nil` `enteredAt` (daemon didn't report one) degrades to
    /// bare-state dedupe.
    private struct Episode: Equatable {
        let state: MuxaAgentState
        let enteredAt: String?
    }

    /// The attention episode last delivered per agent session id.
    private var alarmedEpisodeBySessionId: [String: Episode] = [:]

    /// The alarm to surface for `transition`, or `nil` when quiet (not an
    /// alarming transition, this attention episode was already delivered, or
    /// the transition has no workspace to deliver to).
    ///
    /// - Parameter joined: whether the transition resolved to a workspace.
    ///   An unjoined attention transition never consumes the episode (the
    ///   next joinable pass must alarm), while an unjoined *quiet* transition
    ///   still re-arms the agent so episode memory can't go stale.
    func alarm(for transition: MuxaTransition, joined: Bool) -> AmuxAgentAlarm? {
        let agent = transition.agent
        guard let alarm = AmuxAgentAlarmPolicy.alarm(for: transition), joined else {
            // Quiet state: leaving attention re-arms the agent so its next
            // episode alarms again (also drops memory for stopped agents).
            if !agent.state.needsAttention {
                alarmedEpisodeBySessionId[agent.sessionId] = nil
            }
            return nil
        }
        if agent.state.needsAttention {
            let episode = Episode(state: agent.state, enteredAt: agent.stateEnteredAt)
            guard alarmedEpisodeBySessionId[agent.sessionId] != episode else { return nil }
            alarmedEpisodeBySessionId[agent.sessionId] = episode
        }
        return alarm
    }

    /// Drops episode memory for any session not in `liveSessionIds` — called
    /// after a fresh snapshot so an agent that vanished while blocked (no
    /// `stopped` transition) can't pin its entry forever. Bounds the otherwise
    /// unbounded growth of the dedupe table across the app's lifetime.
    func prune(keeping liveSessionIds: Set<String>) {
        alarmedEpisodeBySessionId = alarmedEpisodeBySessionId.filter {
            liveSessionIds.contains($0.key)
        }
    }
}

/// Holds each "finished" alarm behind a short quiet window, delivering it only
/// if the agent STAYS idle — a goal/mission agent that flashes idle between
/// milestones (or a jittery hook stream) otherwise fires a false "finished"
/// notification per milestone. Attention/error alarms are latency-sensitive
/// and pass through immediately; only the `working → idle` finished edge is
/// debounced (orca uses the same 1.5s window for its hook-done completions).
@MainActor
final class AmuxAgentFinishedAlarmDebounce {
    /// How long the agent must stay idle before "finished" is believed.
    static let quietWindow: Duration = .milliseconds(1500)

    private var pendingBySessionId: [String: Task<Void, Never>] = [:]

    /// Routes `alarm` (already gate-approved, with its resolved workspace):
    /// finished edges are scheduled behind the quiet window; everything else
    /// delivers immediately. Every transition — alarming or not — also feeds
    /// the cancellation side: an agent that resumes working (or enters any
    /// non-idle state) within the window swallows its pending finished alarm.
    func route(
        transition: MuxaTransition,
        alarm: AmuxAgentAlarm?,
        deliver: @escaping @MainActor () -> Void
    ) {
        let sessionId = transition.agent.sessionId
        if transition.to != .idle, let pending = pendingBySessionId.removeValue(forKey: sessionId) {
            // The idle was a milestone flash, not the end of the turn.
            pending.cancel()
        }
        guard alarm != nil else { return }
        guard transition.to == .idle else {
            deliver()
            return
        }
        pendingBySessionId[sessionId]?.cancel()
        pendingBySessionId[sessionId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.quietWindow)
            } catch {
                return
            }
            guard let self, self.pendingBySessionId[sessionId] != nil else { return }
            self.pendingBySessionId[sessionId] = nil
            deliver()
        }
    }
}
