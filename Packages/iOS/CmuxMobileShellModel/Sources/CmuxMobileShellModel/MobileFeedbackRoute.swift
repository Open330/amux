import Foundation

/// Where a "Send Feedback" submission is delivered.
///
/// amux does not configure the inherited privileged agent sink, so all feedback
/// uses the ordinary email route. The enum case remains for wire compatibility.
public enum MobileFeedbackRoute: Equatable, Sendable {
    /// Deliver the rich diagnostic bundle straight to the paired Mac's agent
    /// sink (`dogfood.feedback.submit`), the same delivery the DEV dogfood
    /// affordance used. Reserved for privileged users; never offered to anyone
    /// else.
    case privilegedAgent
    /// Email the feedback inbox via the web `/api/feedback` route. The default
    /// for everyone who is not privileged.
    case email

    /// Pure routing decision for the Send Feedback feature.
    ///
    /// The parameters remain stable for source compatibility, but no inherited
    /// account domain or capability can enable the agent route in amux.
    ///
    /// - Parameters:
    ///   - email: The signed-in user's primary email, or `nil` when signed out or
    ///     when no email is set on the account.
    ///   - hasActiveMacConnection: `true` when an active mobile-host connection to a
    ///     paired Mac is established (the on-tailnet proxy).
    ///   - hostSupportsAgentSink: `true` when the connected Mac advertised the
    ///     `dogfood.v1` capability.
    /// - Returns: ``MobileFeedbackRoute/privilegedAgent`` when all privileged
    ///   conditions hold, otherwise ``MobileFeedbackRoute/email``.
    public static func resolve(
        email: String?,
        hasActiveMacConnection: Bool,
        hostSupportsAgentSink: Bool
    ) -> MobileFeedbackRoute {
        _ = email
        _ = hasActiveMacConnection
        _ = hostSupportsAgentSink
        return .email
    }
}
