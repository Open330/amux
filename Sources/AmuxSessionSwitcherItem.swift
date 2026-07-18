import CmuxMuxa
import Foundation

/// One discovered tmux session presented by the amux session switcher.
struct AmuxSessionSwitcherItem: Identifiable, Equatable, Sendable {
    let host: RemoteTmuxHost
    let session: RemoteTmuxSession
    let agents: [MuxaAgent]

    var id: String { "\(host.id):\(session.id)" }

    var primaryAgent: MuxaAgent? {
        Self.orderedAgents(agents).first
    }

    var mostRecentActivityDate: Date? {
        Self.mostRecentActivityDate(session: session, agents: agents)
    }

    /// The most recent activity date for a session/agent pair without allocating
    /// an `AmuxSessionSwitcherItem`, so per-render callers (e.g. subtitle
    /// formatting) can read it directly.
    static func mostRecentActivityDate(
        session: RemoteTmuxSession,
        agents: [MuxaAgent]
    ) -> Date? {
        agents.compactMap { $0.lastActivityDate ?? $0.startedDate }.max()
            ?? session.createdUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Orders sessions for triage: attention first, then active work, then idle
    /// sessions, with sessions that have no tracked agent last.
    static func ordered(_ items: [AmuxSessionSwitcherItem]) -> [AmuxSessionSwitcherItem] {
        items.sorted(by: itemPrecedes)
    }

    /// Orders open and available targets together without allowing current/open
    /// preference to outrank a session whose agent needs attention.
    static func ordered<Value>(
        _ values: [Value],
        item: KeyPath<Value, AmuxSessionSwitcherItem>,
        isOpen: KeyPath<Value, Bool>,
        isCurrent: KeyPath<Value, Bool>
    ) -> [Value] {
        values.sorted { lhsValue, rhsValue in
            let lhs = lhsValue[keyPath: item]
            let rhs = rhsValue[keyPath: item]
            let lhsAgent = lhs.primaryAgent
            let rhsAgent = rhs.primaryAgent
            let lhsTier = sessionTier(for: lhsAgent)
            let rhsTier = sessionTier(for: rhsAgent)
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            if lhsTier == 0 {
                let lhsBlocked = lhsAgent?.stateEnteredDate ?? lhsAgent?.lastActivityDate ?? .distantFuture
                let rhsBlocked = rhsAgent?.stateEnteredDate ?? rhsAgent?.lastActivityDate ?? .distantFuture
                if lhsBlocked != rhsBlocked { return lhsBlocked < rhsBlocked }
            }

            let lhsCurrent = lhsValue[keyPath: isCurrent]
            let rhsCurrent = rhsValue[keyPath: isCurrent]
            if lhsCurrent != rhsCurrent { return lhsCurrent }

            let lhsOpen = lhsValue[keyPath: isOpen]
            let rhsOpen = rhsValue[keyPath: isOpen]
            if lhsOpen != rhsOpen { return lhsOpen }

            return itemPrecedes(lhs, rhs)
        }
    }

    private static func itemPrecedes(
        _ lhs: AmuxSessionSwitcherItem,
        _ rhs: AmuxSessionSwitcherItem
    ) -> Bool {
        let lhsAgent = lhs.primaryAgent
        let rhsAgent = rhs.primaryAgent
        let lhsTier = sessionTier(for: lhsAgent)
        let rhsTier = sessionTier(for: rhsAgent)
        if lhsTier != rhsTier { return lhsTier < rhsTier }

        if lhsTier == 0 {
            let lhsBlocked = lhsAgent?.stateEnteredDate ?? lhsAgent?.lastActivityDate ?? .distantFuture
            let rhsBlocked = rhsAgent?.stateEnteredDate ?? rhsAgent?.lastActivityDate ?? .distantFuture
            if lhsBlocked != rhsBlocked { return lhsBlocked < rhsBlocked }
        } else {
            let lhsActivity = lhs.mostRecentActivityDate ?? .distantPast
            let rhsActivity = rhs.mostRecentActivityDate ?? .distantPast
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
        }

            let hostOrder = lhs.host.destination.localizedCaseInsensitiveCompare(rhs.host.destination)
            if hostOrder != .orderedSame { return hostOrder == .orderedAscending }
            let nameOrder = lhs.session.name.localizedCaseInsensitiveCompare(rhs.session.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
    }

    static func orderedAgents(_ agents: [MuxaAgent]) -> [MuxaAgent] {
        agents.sorted { lhs, rhs in
            let lhsTier = agentTier(lhs.state)
            let rhsTier = agentTier(rhs.state)
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            if lhs.state.needsAttention {
                let lhsBlocked = lhs.stateEnteredDate ?? lhs.lastActivityDate ?? .distantFuture
                let rhsBlocked = rhs.stateEnteredDate ?? rhs.lastActivityDate ?? .distantFuture
                if lhsBlocked != rhsBlocked { return lhsBlocked < rhsBlocked }
            } else {
                let lhsActivity = lhs.lastActivityDate ?? lhs.startedDate ?? .distantPast
                let rhsActivity = rhs.lastActivityDate ?? rhs.startedDate ?? .distantPast
                if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            }
            return lhs.sessionId < rhs.sessionId
        }
    }

    private static func sessionTier(for agent: MuxaAgent?) -> Int {
        guard let agent else { return 3 }
        if agent.state.needsAttention { return 0 }
        switch agent.state {
        case .starting, .working:
            return 1
        case .idle, .unknown:
            return 2
        case .stopped:
            return 3
        case .waitingInput, .waitingChoice, .error:
            return 0
        }
    }

    private static func agentTier(_ state: MuxaAgentState) -> Int {
        if state.needsAttention { return 0 }
        switch state {
        case .starting, .working:
            return 1
        case .idle, .unknown:
            return 2
        case .stopped:
            return 3
        case .waitingInput, .waitingChoice, .error:
            return 0
        }
    }
}
