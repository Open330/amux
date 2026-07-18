import CmuxMuxa
import Foundation

/// One alarm the agent-observation layer should surface for a state
/// transition — the payload ``AmuxAgentAlarmPolicy`` produces and the
/// notification pipeline renders.
struct AmuxAgentAlarm: Equatable {
    /// Notification title (localized, carries the outcome).
    let title: String
    /// Notification body (the agent's last notification/prompt when known).
    let body: String
    /// Debounce key so one agent flapping through the same state doesn't
    /// spam (scoped per agent session + entered state).
    let cooldownKey: String
    /// Debounce window in seconds.
    let cooldownInterval: TimeInterval
}

/// Maps muxad state transitions to user-facing alarms (plan §4.3: desktop
/// notifications for needs-input / needs-choice / error, plus the
/// work-finished edge) — pure and synchronous so the policy is unit-testable
/// apart from the notification pipeline.
///
/// Works identically for the local daemon and forwarded remote daemons: the
/// transition's origin is irrelevant, only the edge matters.
struct AmuxAgentAlarmPolicy {
    /// Seconds within which a repeat of the same agent+state edge is dropped.
    static let cooldownInterval: TimeInterval = 20

    /// The alarm `transition` warrants, or `nil` for quiet transitions.
    ///
    /// Alarming: any transition into or within `waiting_input` /
    /// `waiting_choice` / `error` (a same-state reconciler-tick refresh must
    /// alarm too — for a pane younger than muxad's inventory it is the first
    /// transition that joins to a workspace; ``AmuxAgentAlarmGate`` dedupes
    /// repeats per episode), plus the `working` → `idle` finished edge.
    /// Everything else — starting, working, stops — is badge-only.
    static func alarm(for transition: MuxaTransition) -> AmuxAgentAlarm? {
        let agent = transition.agent
        let title: String
        let body: String
        switch transition.to {
        case .waitingInput, .waitingChoice:
            title = String(
                format: String(
                    localized: "amux.alarm.waiting.title",
                    defaultValue: "%@ needs your input"
                ),
                displayName(for: agent.kind)
            )
            body = agent.lastNotification ?? agent.lastPrompt ?? ""
        case .error:
            title = String(
                format: String(
                    localized: "amux.alarm.error.title",
                    defaultValue: "%@ hit an error"
                ),
                displayName(for: agent.kind)
            )
            body = agent.lastNotification ?? agent.lastPrompt ?? ""
        case .idle where transition.from == .working:
            title = String(
                format: String(
                    localized: "amux.alarm.finished.title",
                    defaultValue: "%@ finished"
                ),
                displayName(for: agent.kind)
            )
            // A finished turn is described by what the agent answered (or,
            // absent that, what was asked) — never by a stale needs-input
            // notification from earlier in the turn.
            body = agent.lastResponse ?? agent.lastPrompt ?? ""
        default:
            return nil
        }
        return AmuxAgentAlarm(
            title: title,
            body: body,
            cooldownKey: "amux.agent.\(agent.sessionId).\(transition.to.rawValue)",
            cooldownInterval: Self.cooldownInterval
        )
    }

    /// Human-readable product name for an agent kind. Routes through
    /// ``AmuxAgentCatalog/displayName(for:)`` so the alarm/notification copy
    /// shares one spelling with the launch surfaces (an unknown kind shows its
    /// raw wire string — never localized, it's a product name).
    static func displayName(for kind: MuxaAgentKind) -> String {
        AmuxAgentCatalog.displayName(for: kind)
    }
}
