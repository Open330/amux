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

    @Test func inMemoryMessagesAreBoundedAfterManyAppends() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cap = 25
        let store = AmuxOrchestrationStore(
            storageURL: fixture.file,
            maxInMemoryMessages: cap,
            compactionRecordThreshold: 100_000
        )

        for index in 0..<300 {
            _ = try await store.sendMessage(
                type: .status,
                sender: "coordinator",
                recipients: ["worker-a"],
                groups: [],
                taskID: nil,
                body: "update \(index)",
                metadata: [:]
            )
        }

        let inMemory = await store.inMemoryMessageCount
        #expect(inMemory == cap)

        // Long-poll still resolves against the retained recent tail.
        let recent = await store.checkMessages(
            recipient: "worker-a",
            groups: [],
            afterSequence: 0,
            limit: 200,
            waitMilliseconds: 0
        )
        #expect(recent.count == cap)
        #expect(recent.last?.body == "update 299")
    }

    @Test func compactionPreservesLatestStateAndMessageTail() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(
            storageURL: fixture.file,
            maxInMemoryMessages: 100,
            compactionRecordThreshold: 100_000
        )

        let created = try await store.createTask(
            title: "Compact me",
            details: nil,
            creator: "coordinator",
            assignee: "worker-a",
            dependencyIDs: [],
            baseRevision: nil
        )
        let gate = try await store.createGate(
            taskID: created.task.id,
            title: "approval",
            requestedBy: "coordinator"
        )
        let message = try await store.sendMessage(
            type: .status,
            sender: "worker-a",
            recipients: ["coordinator"],
            groups: [],
            taskID: created.task.id,
            body: "progress",
            metadata: [:]
        )
        let heartbeat = try await store.recordHeartbeat(
            worker: "worker-a",
            taskID: created.task.id,
            state: "working"
        )
        // Redundant updates inflate the append log; latest state must survive compaction.
        for index in 0..<40 {
            _ = try await store.updateTask(
                id: created.task.id,
                status: nil,
                assignee: "worker-a",
                details: "iteration \(index)"
            )
        }

        let beforeRecords = await store.persistedRecordCount
        await store.compactForTesting()
        let afterRecords = await store.persistedRecordCount

        #expect(afterRecords < beforeRecords)
        // task(1) + gate(1) + heartbeat(1) + message(1)
        #expect(afterRecords == 4)

        let snapshots = await store.taskSnapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.task.details == "iteration 39")
        #expect(snapshots.first?.heartbeat == heartbeat)

        let gates = await store.listGates()
        #expect(gates == [gate])

        let tail = await store.checkMessages(
            recipient: "coordinator",
            groups: [],
            afterSequence: 0,
            limit: 100,
            waitMilliseconds: 0
        )
        #expect(tail.map(\.id) == [message.id])
    }

    @Test func reinitReconstructsStateFromCompactedFile() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(
            storageURL: fixture.file,
            maxInMemoryMessages: 100,
            compactionRecordThreshold: 100_000
        )

        let created = try await store.createTask(
            title: "Persisted task",
            details: "final details",
            creator: "coordinator",
            assignee: "worker-a",
            dependencyIDs: [],
            baseRevision: "sha"
        )
        let gate = try await store.createGate(
            taskID: created.task.id,
            title: "approval",
            requestedBy: "coordinator"
        )
        let message = try await store.sendMessage(
            type: .dispatch,
            sender: "coordinator",
            recipients: ["worker-a"],
            groups: [],
            taskID: created.task.id,
            body: "go",
            metadata: ["k": "v"]
        )
        _ = try await store.recordHeartbeat(
            worker: "worker-a",
            taskID: created.task.id,
            state: "working"
        )
        for index in 0..<30 {
            _ = try await store.updateTask(
                id: created.task.id,
                status: nil,
                assignee: "worker-a",
                details: "iter \(index)"
            )
        }
        await store.compactForTesting()

        let restored = AmuxOrchestrationStore(
            storageURL: fixture.file,
            maxInMemoryMessages: 100,
            compactionRecordThreshold: 100_000
        )

        let snapshots = await restored.taskSnapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.task.id == created.task.id)
        #expect(snapshots.first?.task.details == "iter 29")
        #expect(snapshots.first?.heartbeat?.worker == "worker-a")

        let gates = await restored.listGates()
        #expect(gates.map(\.id) == [gate.id])

        let messages = await restored.checkMessages(
            recipient: "worker-a",
            groups: [],
            afterSequence: 0,
            limit: 100,
            waitMilliseconds: 0
        )
        #expect(messages.map(\.id) == [message.id])

        // New messages continue from the persisted sequence high-water mark.
        let next = try await restored.sendMessage(
            type: .status,
            sender: "worker-a",
            recipients: ["coordinator"],
            groups: [],
            taskID: nil,
            body: "next",
            metadata: [:]
        )
        #expect(next.sequence == message.sequence + 1)
    }

    @Test func heartbeatsDoNotGrowOnDiskLog() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AmuxOrchestrationStore(
            storageURL: fixture.file,
            maxInMemoryMessages: 100,
            compactionRecordThreshold: 100_000
        )

        let created = try await store.createTask(
            title: "Heartbeat host",
            details: nil,
            creator: "coordinator",
            assignee: "worker-a",
            dependencyIDs: [],
            baseRevision: nil
        )
        let linesAfterTask = try lineCount(of: fixture.file)
        #expect(linesAfterTask == 1)

        for index in 0..<500 {
            _ = try await store.recordHeartbeat(
                worker: "worker-a",
                taskID: created.task.id,
                state: "beat \(index)"
            )
        }

        let linesAfterHeartbeats = try lineCount(of: fixture.file)
        let recordsAfterHeartbeats = await store.persistedRecordCount
        // Heartbeats are memory-only: the append log did not grow at all.
        #expect(linesAfterHeartbeats == linesAfterTask)
        #expect(recordsAfterHeartbeats == 1)

        // On compaction the collapsed latest-per-worker heartbeat is written once.
        await store.compactForTesting()
        let compactedLines = try lineCount(of: fixture.file)
        let recordsAfterCompaction = await store.persistedRecordCount
        // task(1) + collapsed heartbeat(1)
        #expect(compactedLines == 2)
        #expect(recordsAfterCompaction == 2)
    }

    private func lineCount(of url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).count
    }

    private func makeFixture() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-orchestration-tests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("state/orchestration.ndjson"))
    }
}
