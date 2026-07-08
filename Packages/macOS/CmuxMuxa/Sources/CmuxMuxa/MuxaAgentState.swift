/// The lifecycle state muxad tracks for an agent, as carried on the wire.
///
/// muxa's versioning policy bumps its protocol version when it adds enum
/// variants, but this client stays lenient anyway: an unrecognized state
/// decodes as ``unknown(_:)`` instead of failing the whole payload, so a
/// newer daemon never breaks snapshot/subscribe decoding.
public enum MuxaAgentState: Sendable, Equatable, Hashable {
    /// Session opened but no activity classified yet.
    case starting
    /// The agent is actively working (tool running or responding).
    case working
    /// The agent finished its turn and nothing is pending.
    case idle
    /// Blocked on free-text user input or a permission prompt.
    case waitingInput
    /// Blocked on a numbered menu selection (protocol v2+; e.g. Claude Code's
    /// `AskUserQuestion`).
    case waitingChoice
    /// The agent reported an error.
    case error
    /// The session ended.
    case stopped
    /// A state string this client version does not recognize; carries the raw
    /// wire value.
    case unknown(String)

    /// The exact wire string for this state.
    public var rawValue: String {
        switch self {
        case .starting: "starting"
        case .working: "working"
        case .idle: "idle"
        case .waitingInput: "waiting_input"
        case .waitingChoice: "waiting_choice"
        case .error: "error"
        case .stopped: "stopped"
        case .unknown(let raw): raw
        }
    }

    /// Whether the agent is blocked on the user (input, choice, or error) —
    /// the states an attend/notification surface should escalate.
    public var needsAttention: Bool {
        switch self {
        case .waitingInput, .waitingChoice, .error: true
        case .starting, .working, .idle, .stopped, .unknown: false
        }
    }

    init(wireValue: String) {
        switch wireValue {
        case "starting": self = .starting
        case "working": self = .working
        case "idle": self = .idle
        case "waiting_input": self = .waitingInput
        case "waiting_choice": self = .waitingChoice
        case "error": self = .error
        case "stopped": self = .stopped
        default: self = .unknown(wireValue)
        }
    }
}

extension MuxaAgentState: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
