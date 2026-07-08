/// One agent state change streamed by muxad's `subscribe` method.
///
/// Each line on a subscribed connection is one transition: the state edge
/// (`from` → `to`) plus the full post-transition agent row.
public struct MuxaTransition: Sendable, Equatable, Codable {
    /// The state the agent left.
    public let from: MuxaAgentState
    /// The state the agent entered.
    public let to: MuxaAgentState
    /// The full agent row after the transition was applied.
    public let agent: MuxaAgent

    public init(from: MuxaAgentState, to: MuxaAgentState, agent: MuxaAgent) {
        self.from = from
        self.to = to
        self.agent = agent
    }
}
