import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AmuxOrchestrationStoreTests {
    @Test func messagesSupportDirectGroupCursorAndPersistence() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(storageURL: fixture.file)

        let direct = try await store.sendMessage(
            type: .dispatch,
            sender: "coordinator",
            recipients: ["worker-a"],
            groups: [],
            taskID: nil,
            body: "inspect attach routing",
            metadata: ["priority": "high"]
        )
        let grouped = try await store.sendMessage(
            type: .status,
            sender: "worker-b",
            recipients: [],
            groups: ["reviewers"],
            taskID: nil,
            body: "review ready",
            metadata: [:]
        )

        let firstPage = await store.checkMessages(
            recipient: "worker-a",
            groups: [],
            afterSequence: 0,
            limit: 10,
            waitMilliseconds: 0
        )
        #expect(firstPage.map(\.id) == [direct.id])

        let reviewerPage = await store.checkMessages(
            recipient: "reviewer-1",
            groups: ["reviewers"],
            afterSequence: direct.sequence,
            limit: 10,
            waitMilliseconds: 0
        )
        #expect(reviewerPage.map(\.id) == [grouped.id])

        let restored = AmuxOrchestrationStore(storageURL: fixture.file)
        let restoredPage = await restored.checkMessages(
            recipient: "worker-a",
            groups: [],
            afterSequence: 0,
            limit: 10,
            waitMilliseconds: 0
        )
        #expect(restoredPage.map(\.id) == [direct.id])
    }

    @Test func longPollReturnsWhenMatchingMessageArrives() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(storageURL: fixture.file)

        async let waiting = store.checkMessages(
            recipient: "worker-a",
            groups: [],
            afterSequence: 0,
            limit: 10,
            waitMilliseconds: 2_000
        )
        try await Task.sleep(for: .milliseconds(100))
        let sent = try await store.sendMessage(
            type: .handoff,
            sender: "coordinator",
            recipients: ["worker-a"],
            groups: [],
            taskID: nil,
            body: "continue",
            metadata: [:]
        )
        let messages = await waiting

        #expect(messages.map(\.id) == [sent.id])
    }

    @Test func persistedCoordinationStateIsOwnerOnly() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(storageURL: fixture.file)

        _ = try await store.sendMessage(
            type: .status,
            sender: "worker-a",
            recipients: ["coordinator"],
            groups: [],
            taskID: nil,
            body: "contains private work context",
            metadata: [:]
        )

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.file.deletingLastPathComponent().path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func dependenciesAndDecisionGatesBlockTaskStart() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(storageURL: fixture.file)

        let prerequisite = try await store.createTask(
            title: "Implement stable attach",
            details: nil,
            creator: "coordinator",
            assignee: "worker-a",
            dependencyIDs: [],
            baseRevision: "abc123"
        )
        let dependent = try await store.createTask(
            title: "Integrate and review",
            details: nil,
            creator: "coordinator",
            assignee: "reviewer",
            dependencyIDs: [prerequisite.task.id],
            baseRevision: "abc123"
        )

        await #expect(throws: AmuxOrchestrationError.dependencyNotReady([prerequisite.task.id])) {
            try await store.updateTask(id: dependent.task.id, status: .inProgress, assignee: nil, details: nil)
        }
        _ = try await store.updateTask(
            id: prerequisite.task.id,
            status: .completed,
            assignee: nil,
            details: nil
        )
        let gate = try await store.createGate(
            taskID: dependent.task.id,
            title: "Dogfood approval",
            requestedBy: "coordinator"
        )
        await #expect(throws: AmuxOrchestrationError.gateNotReady([gate.id])) {
            try await store.updateTask(id: dependent.task.id, status: .inProgress, assignee: nil, details: nil)
        }
        _ = try await store.resolveGate(
            id: gate.id,
            status: .approved,
            resolvedBy: "maintainer",
            note: "verified"
        )
        let started = try await store.updateTask(
            id: dependent.task.id,
            status: .inProgress,
            assignee: nil,
            details: nil
        )

        #expect(started.task.status == .inProgress)
        #expect(started.isRunnable)
    }

    @Test func heartbeatIsCorrelatedAndFreshForRunningTask() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(storageURL: fixture.file)
        let created = try await store.createTask(
            title: "Review switcher",
            details: nil,
            creator: "coordinator",
            assignee: "reviewer",
            dependencyIDs: [],
            baseRevision: nil
        )
        _ = try await store.updateTask(
            id: created.task.id,
            status: .inProgress,
            assignee: nil,
            details: nil
        )
        let heartbeat = try await store.recordHeartbeat(
            worker: "reviewer",
            taskID: created.task.id,
            state: "working"
        )
        let snapshots = await store.taskSnapshots(staleAfter: .seconds(90))

        #expect(snapshots.first?.heartbeat == heartbeat)
        #expect(snapshots.first?.isHeartbeatStale == false)
    }

    @Test func staleBasePreflightRejectsDispatchTask() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(storageURL: fixture.file)

        await #expect(throws: AmuxOrchestrationError.staleBase(distance: 21, maximum: 20)) {
            try await store.createTask(
                title: "Dispatch stale work",
                details: nil,
                creator: "coordinator",
                assignee: "worker-a",
                dependencyIDs: [],
                baseRevision: "old-sha",
                baseDistance: 21
            )
        }
    }

    private func makeFixture() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-orchestration-tests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("state/orchestration.ndjson"))
    }
}
