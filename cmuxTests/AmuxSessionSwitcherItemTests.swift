import CmuxMuxa
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AmuxSessionSwitcherItemTests {
    private func agent(
        _ id: String,
        state: MuxaAgentState,
        activity: String,
        stateEntered: String? = nil
    ) -> MuxaAgent {
        MuxaAgent(
            kind: .codex,
            sessionId: id,
            tmuxSession: id,
            state: state,
            lastActivityAt: activity,
            stateEnteredAt: stateEntered
        )
    }

    private func item(
        _ name: String,
        id: Int,
        agents: [MuxaAgent] = [],
        createdUnix: Int? = nil
    ) -> AmuxSessionSwitcherItem {
        AmuxSessionSwitcherItem(
            host: .amuxLocal(),
            session: RemoteTmuxSession(
                id: "$\(id)",
                name: name,
                windowCount: 1,
                attached: false,
                createdUnix: createdUnix
            ),
            agents: agents
        )
    }

    @Test func ordersAttentionBeforeActiveIdleAndUntrackedSessions() {
        let olderWaiting = item(
            "older-waiting",
            id: 1,
            agents: [agent(
                "waiting-1",
                state: .waitingInput,
                activity: "2026-07-10T08:00:00Z",
                stateEntered: "2026-07-10T08:05:00Z"
            )]
        )
        let newerWaiting = item(
            "newer-waiting",
            id: 2,
            agents: [agent(
                "waiting-2",
                state: .waitingChoice,
                activity: "2026-07-10T08:30:00Z",
                stateEntered: "2026-07-10T08:35:00Z"
            )]
        )
        let working = item(
            "working",
            id: 3,
            agents: [agent("working", state: .working, activity: "2026-07-10T08:40:00Z")]
        )
        let idle = item(
            "idle",
            id: 4,
            agents: [agent("idle", state: .idle, activity: "2026-07-10T08:50:00Z")]
        )
        let untracked = item("untracked", id: 5, createdUnix: 1_752_135_600)

        let names = AmuxSessionSwitcherItem.ordered([
            idle,
            untracked,
            newerWaiting,
            working,
            olderWaiting,
        ]).map(\.session.name)

        #expect(names == [
            "older-waiting",
            "newer-waiting",
            "working",
            "idle",
            "untracked",
        ])
    }

    @Test func primaryAgentPrefersLongestWaitingAgent() {
        let active = agent("active", state: .working, activity: "2026-07-10T09:00:00Z")
        let newerWaiting = agent(
            "newer",
            state: .waitingChoice,
            activity: "2026-07-10T08:45:00Z",
            stateEntered: "2026-07-10T08:50:00Z"
        )
        let olderWaiting = agent(
            "older",
            state: .waitingInput,
            activity: "2026-07-10T08:15:00Z",
            stateEntered: "2026-07-10T08:20:00Z"
        )

        #expect(item("agents", id: 1, agents: [active, newerWaiting, olderWaiting]).primaryAgent?.sessionId == "older")
    }

    @MainActor
    @Test func hostListKeepsLocalEndpointsFirstAndDeduplicatesSSHHosts() {
        let alpha = RemoteTmuxHost(destination: "alpha")
        let beta = RemoteTmuxHost(destination: "beta")

        let hosts = AppDelegate.amuxSessionSwitcherHosts(
            remoteSyncHosts: [beta, alpha],
            activeSSHHosts: [alpha]
        )

        #expect(hosts.map(\.kind) == [.localAmux, .localDefault, .ssh, .ssh])
        #expect(hosts.map(\.destination) == ["amux-local", "localhost", "alpha", "beta"])
    }

    @Test func presentationMakesHostIdentityAndAgentMetadataSearchable() {
        let host = RemoteTmuxHost(destination: "builder@example.com")
        let tracked = MuxaAgent(
            kind: .codex,
            sessionId: "agent-1",
            tmuxSession: "main",
            cwd: "/work/amux",
            state: .waitingInput,
            lastPrompt: "Review pull request seven",
            model: "gpt-5"
        )
        let presentation = AmuxSessionSwitcherPresentation()

        let title = presentation.rowTitle(name: "main", host: host)
        let keywords = presentation.searchKeywords(
            host: host,
            sessionName: "main",
            agents: [tracked]
        )

        #expect(title.contains("main"))
        #expect(title.contains("builder@example.com"))
        #expect(keywords.contains("/work/amux"))
        #expect(keywords.contains("Review pull request seven"))
        #expect(keywords.contains("gpt-5"))
    }
}
