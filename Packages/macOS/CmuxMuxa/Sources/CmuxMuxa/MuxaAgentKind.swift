/// Which agent CLI a muxad row belongs to, as carried on the wire.
///
/// Lenient like ``MuxaAgentState``: an unrecognized kind decodes as
/// ``unknown(_:)`` so new adapters in a future muxad never break decoding.
public enum MuxaAgentKind: Sendable, Equatable, Hashable {
    /// Anthropic Claude Code.
    case claudeCode
    /// OpenAI Codex CLI.
    case codex
    /// Google Gemini CLI.
    case geminiCli
    /// opencode.
    case opencode
    /// A kind string this client version does not recognize; carries the raw
    /// wire value.
    case unknown(String)

    /// The exact wire string for this kind.
    public var rawValue: String {
        switch self {
        case .claudeCode: "claude_code"
        case .codex: "codex"
        case .geminiCli: "gemini_cli"
        case .opencode: "opencode"
        case .unknown(let raw): raw
        }
    }

    init(wireValue: String) {
        switch wireValue {
        case "claude_code": self = .claudeCode
        case "codex": self = .codex
        case "gemini_cli": self = .geminiCli
        case "opencode": self = .opencode
        default: self = .unknown(wireValue)
        }
    }
}

extension MuxaAgentKind: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
