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
    /// The attention state last delivered per agent session id.
    private var alarmedStateBySessionId: [String: MuxaAgentState] = [:]

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
                alarmedStateBySessionId[agent.sessionId] = nil
            }
            return nil
        }
        if agent.state.needsAttention {
            guard alarmedStateBySessionId[agent.sessionId] != agent.state else { return nil }
            alarmedStateBySessionId[agent.sessionId] = agent.state
        }
        return alarm
    }
}
