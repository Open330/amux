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
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [local, remote])
        // start() publishes the loading transition synchronously onto the
        // observable state that ContentView renders from.
        #expect(coordinator.loadingHosts.map(\.id) == [local.id, remote.id])
        #expect(coordinator.isLoading)
        let loadingRevision = coordinator.revision
        _ = await requests.next()
        _ = await requests.next()

        loader.succeed(local, items: [item("local-work", host: local, id: 1)])
        #expect(await waitUntil { coordinator.items.map(\.session.name) == ["local-work"] })
        #expect(coordinator.revision > loadingRevision)
        #expect(coordinator.loadingHosts == [remote])
        #expect(coordinator.isLoading)
        #expect(coordinator.failedHosts.isEmpty)
        let progressiveRevision = coordinator.revision

        loader.fail(remote)
        #expect(await waitUntil { !coordinator.isLoading })
        #expect(coordinator.revision > progressiveRevision)
        #expect(coordinator.items.map(\.session.name) == ["local-work"])
        #expect(coordinator.loadingHosts.isEmpty)
        #expect(coordinator.failedHosts == [remote])
    }

    @Test func refreshPreservesRowsAndRejectsStaleResults() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let host = RemoteTmuxHost.amuxLocal()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [host])
        _ = await requests.next()
        loader.succeed(host, items: [item("first", host: host, id: 1)])
        #expect(await waitUntil { coordinator.items.map(\.session.name) == ["first"] })

        coordinator.refresh()
        // refresh keeps the prior rows visible while it reloads.
        #expect(coordinator.items.map(\.session.name) == ["first"])
        #expect(coordinator.loadingHosts == [host])
        _ = await requests.next()

        coordinator.refresh()
        #expect(coordinator.items.map(\.session.name) == ["first"])
        _ = await requests.next()

        loader.succeed(host, items: [item("stale", host: host, id: 2)])
        loader.succeed(host, items: [item("fresh", host: host, id: 3)])
        #expect(await waitUntil {
            coordinator.items.map(\.session.name) == ["fresh"] && !coordinator.isLoading
        })
        #expect(coordinator.loadingHosts.isEmpty)
    }

    @Test func refreshAfterCancelDoesNotPublishAnEmptyList() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let host = RemoteTmuxHost.amuxLocal()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [host])
        _ = await requests.next()
        loader.succeed(host, items: [item("only", host: host, id: 1)])
        #expect(await waitUntil { coordinator.items.map(\.session.name) == ["only"] })

        coordinator.cancel()
        #expect(coordinator.items.isEmpty)
        #expect(coordinator.hostCount == 0)
        let revisionAfterCancel = coordinator.revision

        // With no hosts left, refresh() must be a no-op: it must not reload, must
        // not touch the empty state, and must not bump the revision.
        coordinator.refresh()
        #expect(coordinator.revision == revisionAfterCancel)
        #expect(coordinator.items.isEmpty)
        #expect(!coordinator.isLoading)
    }

    @Test func duplicateHostsLoadOnce() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let host = RemoteTmuxHost.amuxLocal()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [host, host])
        // A duplicate endpoint is collapsed, so only one host loads.
        #expect(coordinator.loadingHosts == [host])
        #expect(coordinator.hostCount == 1)
        _ = await requests.next()

        loader.succeed(host, items: [item("once", host: host, id: 1)])
        #expect(await waitUntil { !coordinator.isLoading })
        #expect(coordinator.items.map(\.session.name) == ["once"])
        #expect(coordinator.loadingHosts.isEmpty)
    }

    @Test func cancelClearsRowsAndOldCompletionCannotWin() async throws {
        let loader = ControlledAmuxSessionSwitcherLoader()
        let coordinator = AmuxSessionSwitcherCoordinator(loader: loader)
        let host = RemoteTmuxHost.amuxLocal()
        var requests = loader.requests().makeAsyncIterator()

        coordinator.start(hosts: [host])
        _ = await requests.next()
        coordinator.cancel()
        #expect(coordinator.hostCount == 0)
        #expect(coordinator.items.isEmpty)
        #expect(!coordinator.isLoading)

        coordinator.start(hosts: [host])
        _ = await requests.next()
        loader.succeed(host, items: [item("cancelled", host: host, id: 1)])
        loader.succeed(host, items: [item("current", host: host, id: 2)])
        #expect(await waitUntil { coordinator.items.map(\.session.name) == ["current"] })
    }

    /// Yields to the main actor until `predicate` holds or the bounded iteration
    /// budget is exhausted, letting the coordinator's per-host load tasks run.
    @discardableResult
    private func waitUntil(
        iterations: Int = 1000,
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
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
