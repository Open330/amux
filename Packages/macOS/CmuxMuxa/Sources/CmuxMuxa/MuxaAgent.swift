import Foundation

/// One live agent row from muxad's registry (`snapshot`, `by_pane`, and the
/// `agent` field of every ``MuxaTransition``).
///
/// Wire-faithful DTO: timestamps stay RFC 3339 strings (muxad mixes
/// fractional and whole-second forms); use ``lastActivityDate`` for a parsed
/// value. Unknown wire fields are ignored, so a newer daemon's additive
/// fields never break decoding.
public struct MuxaAgent: Sendable, Equatable, Codable {
    /// Which agent CLI this row belongs to.
    public let kind: MuxaAgentKind
    /// The agent's own session identifier (e.g. Claude Code's session UUID).
    public let sessionId: String
    /// The tmux pane id (`%N`) the agent runs in, when correlated.
    public let pane: String?
    /// The tmux session name the pane belongs to, when correlated.
    public let tmuxSession: String?
    /// The agent process's working directory, when known.
    public let cwd: String?
    /// Current lifecycle state.
    public let state: MuxaAgentState
    /// The most recent user prompt (truncated by muxad).
    public let lastPrompt: String?
    /// The most recent attention notification message.
    public let lastNotification: String?
    /// The most recent assistant response text (truncated by muxad).
    public let lastResponse: String?
    /// The model reported by the agent's heartbeat, when known.
    public let model: String?
    /// Context-window usage percentage from the last heartbeat, when known.
    public let contextUsedPct: Double?
    /// Accumulated cost in USD from the last heartbeat, when known.
    public let costUsd: Double?
    /// RFC 3339 timestamp of when the session started.
    public let startedAt: String?
    /// RFC 3339 timestamp of the agent's last activity.
    public let lastActivityAt: String?
    /// RFC 3339 timestamp of when the agent entered its current ``state`` —
    /// the sort key for "longest blocked" (attend).
    public let stateEnteredAt: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case sessionId = "session_id"
        case pane
        case tmuxSession = "tmux_session"
        case cwd
        case state
        case lastPrompt = "last_prompt"
        case lastNotification = "last_notification"
        case lastResponse = "last_response"
        case model
        case contextUsedPct = "context_used_pct"
        case costUsd = "cost_usd"
        case startedAt = "started_at"
        case lastActivityAt = "last_activity_at"
        case stateEnteredAt = "state_entered_at"
    }

    /// ``lastActivityAt`` parsed as a `Date`, accepting both fractional and
    /// whole-second RFC 3339 forms. `nil` when absent or unparseable.
    public var lastActivityDate: Date? {
        lastActivityAt.flatMap(Self.parseTimestamp)
    }

    /// ``startedAt`` parsed as a `Date` (same parsing rules as
    /// ``lastActivityDate``).
    public var startedDate: Date? {
        startedAt.flatMap(Self.parseTimestamp)
    }

    /// ``stateEnteredAt`` parsed as a `Date` (same parsing rules as
    /// ``lastActivityDate``).
    public var stateEnteredDate: Date? {
        stateEnteredAt.flatMap(Self.parseTimestamp)
    }

    /// Parses muxad's RFC 3339 timestamps, which mix fractional
    /// (`…T14:36:14.449918Z`) and whole-second (`…T14:36:14Z`) forms.
    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }

    public init(
        kind: MuxaAgentKind,
        sessionId: String,
        pane: String? = nil,
        tmuxSession: String? = nil,
        cwd: String? = nil,
        state: MuxaAgentState,
        lastPrompt: String? = nil,
        lastNotification: String? = nil,
        lastResponse: String? = nil,
        model: String? = nil,
        contextUsedPct: Double? = nil,
        costUsd: Double? = nil,
        startedAt: String? = nil,
        lastActivityAt: String? = nil,
        stateEnteredAt: String? = nil
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.pane = pane
        self.tmuxSession = tmuxSession
        self.cwd = cwd
        self.state = state
        self.lastPrompt = lastPrompt
        self.lastNotification = lastNotification
        self.lastResponse = lastResponse
        self.model = model
        self.contextUsedPct = contextUsedPct
        self.costUsd = costUsd
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.stateEnteredAt = stateEnteredAt
    }
}
