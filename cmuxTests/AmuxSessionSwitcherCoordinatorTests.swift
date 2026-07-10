import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct AmuxSessionSwitcherCoordinatorTests {
    @Test func publishesFastHostResultsWhileAnotherHostIsStillLoading() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let local = RemoteTmuxHost.amuxLocal()
        let remote = RemoteTmuxHost(destination: "slow-builder")
        var changes = coordinator.changes().makeAsyncIterator()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [local, remote])
        let loading = try #require(await changes.next())
        #expect(loading.loadingHosts.map(\.id) == [local.id, remote.id])
        _ = await requests.next()
        _ = await requests.next()

        loader.succeed(local, items: [item("local-work", host: local, id: 1)])
        let progressive = try #require(await changes.next())
        #expect(progressive.items.map(\.session.name) == ["local-work"])
        #expect(progressive.loadingHosts == [remote])
        #expect(progressive.failedHosts.isEmpty)

        loader.fail(remote)
        let completed = try #require(await changes.next())
        #expect(completed.items.map(\.session.name) == ["local-work"])
        #expect(completed.loadingHosts.isEmpty)
        #expect(completed.failedHosts == [remote])
    }

    @Test func refreshPreservesRowsAndRejectsStaleResults() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let host = RemoteTmuxHost.amuxLocal()
        var changes = coordinator.changes().makeAsyncIterator()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [host])
        _ = await changes.next()
        _ = await requests.next()
        loader.succeed(host, items: [item("first", host: host, id: 1)])
        let first = try #require(await changes.next())
        #expect(first.items.map(\.session.name) == ["first"])

        coordinator.refresh()
        let refreshing = try #require(await changes.next())
        #expect(refreshing.items.map(\.session.name) == ["first"])
        #expect(refreshing.loadingHosts == [host])
        _ = await requests.next()

        coordinator.refresh()
        let newestRefresh = try #require(await changes.next())
        #expect(newestRefresh.items.map(\.session.name) == ["first"])
        _ = await requests.next()

        loader.succeed(host, items: [item("stale", host: host, id: 2)])
        loader.succeed(host, items: [item("fresh", host: host, id: 3)])
        let completed = try #require(await changes.next())
        #expect(completed.items.map(\.session.name) == ["fresh"])
        #expect(completed.loadingHosts.isEmpty)
    }

    @Test func cancelClearsRowsAndOldCompletionCannotWin() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let host = RemoteTmuxHost.amuxLocal()
        var changes = coordinator.changes().makeAsyncIterator()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [host])
        _ = await changes.next()
        _ = await requests.next()
        coordinator.cancel()
        let cancelled = try #require(await changes.next())
        #expect(cancelled.hostCount == 0)
        #expect(cancelled.items.isEmpty)

        coordinator.start(hosts: [host])
        _ = await changes.next()
        _ = await requests.next()
        loader.succeed(host, items: [item("cancelled", host: host, id: 1)])
        loader.succeed(host, items: [item("current", host: host, id: 2)])
        let completed = try #require(await changes.next())
        #expect(completed.items.map(\.session.name) == ["current"])
    }

    private func item(
        _ name: String,
        host: RemoteTmuxHost,
        id: Int
    ) -> AmuxSessionSwitcherItem {
        AmuxSessionSwitcherItem(
            host: host,
            session: RemoteTmuxSession(
                id: "$\(id)",
                name: name,
                windowCount: id,
                attached: false,
                createdUnix: 1_752_135_600 + id
            ),
            agents: []
        )
    }
}
