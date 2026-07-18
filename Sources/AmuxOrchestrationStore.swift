import Foundation

actor AmuxOrchestrationStore {
    private struct MessageWaiter {
        let recipient: String
        let groups: Set<String>
        let afterSequence: Int64
        let continuation: AsyncStream<Void>.Continuation
    }

    private struct Record: Codable {
        enum Kind: String, Codable {
            case message
            case task
            case gate
            case heartbeat
        }

        let kind: Kind
        let message: AmuxOrchestrationMessage?
        let task: AmuxOrchestrationTask?
        let gate: AmuxOrchestrationGate?
        let heartbeat: AmuxOrchestrationHeartbeat?
    }

    static let defaultStorageURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/amux/orchestration.ndjson")

    private let storageURL: URL
    // Bounded-durability contract for the message log: only the most recent
    // `maxInMemoryMessages` messages are retained — in memory AND on disk (older
    // ones are dropped on trim/compaction). `checkMessages` long-poll is served
    // from this recent tail; this is a live coordination channel, not a durable
    // event store. A consumer that resumes from a sequence older than the retained
    // floor receives the recent tail (not the full backlog) and can detect the
    // gap via a discontinuity in the returned messages' sequence numbers. The
    // default (500) comfortably exceeds the per-poll `limit`, so a caught-up
    // consumer never observes a gap; raise it via `init` if a use case needs a
    // deeper replay window.
    private let maxInMemoryMessages: Int
    // Rewrite the append-only log as a compact snapshot once it grows past this many
    // records, so on-disk size and init replay cost stay bounded across the app's life.
    private let compactionRecordThreshold: Int
    private var nextMessageSequence: Int64 = 1
    private var messages: [AmuxOrchestrationMessage] = []
    private var tasks: [UUID: AmuxOrchestrationTask] = [:]
    private var gates: [UUID: AmuxOrchestrationGate] = [:]
    private var heartbeats: [String: AmuxOrchestrationHeartbeat] = [:]
    private var messageWaiters: [UUID: MessageWaiter] = [:]
    private let encoder: JSONEncoder
    // Number of records currently written to `storageURL`; drives compaction.
    private(set) var persistedRecordCount = 0

    init(
        storageURL: URL = AmuxOrchestrationStore.defaultStorageURL,
        maxInMemoryMessages: Int = 500,
        compactionRecordThreshold: Int = 1000
    ) {
        self.storageURL = storageURL
        self.maxInMemoryMessages = max(1, maxInMemoryMessages)
        self.compactionRecordThreshold = max(1, compactionRecordThreshold)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL), !data.isEmpty else { return }
        var recordsRead = 0
        for line in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else { continue }
            recordsRead += 1
            switch record.kind {
            case .message:
                if let message = record.message {
                    messages.append(message)
                    nextMessageSequence = max(nextMessageSequence, message.sequence + 1)
                }
            case .task:
                if let task = record.task { tasks[task.id] = task }
            case .gate:
                if let gate = record.gate { gates[gate.id] = gate }
            case .heartbeat:
                if let heartbeat = record.heartbeat { heartbeats[heartbeat.worker] = heartbeat }
            }
        }
        messages.sort { $0.sequence < $1.sequence }
        Self.trim(&messages, to: self.maxInMemoryMessages)
        persistedRecordCount = recordsRead
        // A large legacy/append-only file is replayed once here, then rewritten as a
        // compact snapshot so subsequent launches reconstruct state quickly.
        let liveCount = tasks.count + gates.count + heartbeats.count + messages.count
        if Self.shouldCompact(
            persistedRecordCount: recordsRead,
            liveRecordCount: liveCount,
            threshold: self.compactionRecordThreshold
        ), let count = try? Self.writeSnapshot(
            to: storageURL,
            encoder: encoder,
            tasks: tasks,
            gates: gates,
            heartbeats: heartbeats,
            messages: messages,
            messageTail: self.maxInMemoryMessages
        ) {
            persistedRecordCount = count
        }
    }

    func sendMessage(
        type: AmuxOrchestrationMessageType,
        sender: String,
        recipients: [String],
        groups: [String],
        taskID: UUID?,
        body: String,
        metadata: [String: String]
    ) throws -> AmuxOrchestrationMessage {
        guard !sender.isEmpty else { throw AmuxOrchestrationError.invalidValue("sender") }
        guard !body.isEmpty else { throw AmuxOrchestrationError.invalidValue("body") }
        guard !recipients.isEmpty || !groups.isEmpty else {
            throw AmuxOrchestrationError.invalidValue("recipients")
        }
        if let taskID, tasks[taskID] == nil {
            throw AmuxOrchestrationError.notFound("task_id")
        }

        let message = AmuxOrchestrationMessage(
            sequence: nextMessageSequence,
            id: UUID(),
            type: type,
            sender: sender,
            recipients: Self.normalized(recipients),
            groups: Self.normalized(groups),
            taskID: taskID,
            body: body,
            metadata: metadata,
            createdAt: Date()
        )
        try append(Record(kind: .message, message: message, task: nil, gate: nil, heartbeat: nil))
        nextMessageSequence += 1
        messages.append(message)
        notifyMessageWaiters(matching: message)
        Self.trim(&messages, to: maxInMemoryMessages)
        compactIfNeeded()
        return message
    }

    func checkMessages(
        recipient: String,
        groups: Set<String>,
        afterSequence: Int64,
        limit: Int,
        waitMilliseconds: Int
    ) async -> [AmuxOrchestrationMessage] {
        let boundedLimit = min(max(limit, 1), 200)
        let boundedWait = min(max(waitMilliseconds, 0), 300_000)
        let available = matchingMessages(
            recipient: recipient,
            groups: groups,
            afterSequence: afterSequence,
            limit: boundedLimit
        )
        guard available.isEmpty, boundedWait > 0, !Task.isCancelled else {
            return available
        }

        let waiterID = UUID()
        let signal = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        messageWaiters[waiterID] = MessageWaiter(
            recipient: recipient,
            groups: groups,
            afterSequence: afterSequence,
            continuation: signal.continuation
        )
        // This is a real long-poll deadline. Message arrival signals the stream
        // directly, so the store does not wake periodically while waiting.
        let timeoutTask = Task {
            try? await Task.sleep(for: .milliseconds(boundedWait))
            guard !Task.isCancelled else { return }
            signal.continuation.yield(())
        }
        defer {
            timeoutTask.cancel()
            messageWaiters[waiterID] = nil
            signal.continuation.finish()
        }

        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        return matchingMessages(
            recipient: recipient,
            groups: groups,
            afterSequence: afterSequence,
            limit: boundedLimit
        )
    }

    func createTask(
        title: String,
        details: String?,
        creator: String,
        assignee: String?,
        dependencyIDs: [UUID],
        baseRevision: String?,
        baseDistance: Int? = nil
    ) throws -> AmuxOrchestrationTaskSnapshot {
        guard !title.isEmpty else { throw AmuxOrchestrationError.invalidValue("title") }
        guard !creator.isEmpty else { throw AmuxOrchestrationError.invalidValue("creator") }
        let dependencyIDs = Array(Set(dependencyIDs)).sorted { $0.uuidString < $1.uuidString }
        let missing = dependencyIDs.filter { tasks[$0] == nil }
        guard missing.isEmpty else { throw AmuxOrchestrationError.notFound("dependency_ids") }
        if let baseDistance {
            guard baseDistance >= 0 else { throw AmuxOrchestrationError.invalidValue("base_distance") }
            guard baseDistance <= 20 else {
                throw AmuxOrchestrationError.staleBase(distance: baseDistance, maximum: 20)
            }
        }

        let now = Date()
        let task = AmuxOrchestrationTask(
            id: UUID(),
            title: title,
            details: details,
            creator: creator,
            assignee: assignee,
            status: .pending,
            dependencyIDs: dependencyIDs,
            baseRevision: baseRevision,
            baseDistance: baseDistance,
            createdAt: now,
            updatedAt: now
        )
        try append(Record(kind: .task, message: nil, task: task, gate: nil, heartbeat: nil))
        tasks[task.id] = task
        compactIfNeeded()
        return snapshot(for: task)
    }

    func updateTask(
        id: UUID,
        status: AmuxOrchestrationTaskStatus?,
        assignee: String?,
        details: String?
    ) throws -> AmuxOrchestrationTaskSnapshot {
        guard var task = tasks[id] else { throw AmuxOrchestrationError.notFound("task_id") }
        if let status, status == .inProgress || status == .completed {
            let incomplete = task.dependencyIDs.filter { tasks[$0]?.status != .completed }
            guard incomplete.isEmpty else { throw AmuxOrchestrationError.dependencyNotReady(incomplete) }
            let pendingGates = gates.values
                .filter { $0.taskID == id && $0.status != .approved && $0.status != .cancelled }
                .map(\.id)
            guard pendingGates.isEmpty else { throw AmuxOrchestrationError.gateNotReady(pendingGates) }
        }
        if let status { task.status = status }
        if let assignee { task.assignee = assignee.isEmpty ? nil : assignee }
        if let details { task.details = details.isEmpty ? nil : details }
        task.updatedAt = Date()
        try append(Record(kind: .task, message: nil, task: task, gate: nil, heartbeat: nil))
        tasks[id] = task
        compactIfNeeded()
        return snapshot(for: task)
    }

    func taskSnapshots(
        status: AmuxOrchestrationTaskStatus? = nil,
        assignee: String? = nil,
        staleAfter: Duration = .seconds(90)
    ) -> [AmuxOrchestrationTaskSnapshot] {
        tasks.values
            .filter { status == nil || $0.status == status }
            .filter { assignee == nil || $0.assignee == assignee }
            .sorted { lhs, rhs in
                if lhs.status == rhs.status { return lhs.createdAt < rhs.createdAt }
                return lhs.status.rawValue < rhs.status.rawValue
            }
            .map { snapshot(for: $0, staleAfter: staleAfter) }
    }

    func createGate(taskID: UUID, title: String, requestedBy: String) throws -> AmuxOrchestrationGate {
        guard tasks[taskID] != nil else { throw AmuxOrchestrationError.notFound("task_id") }
        guard !title.isEmpty else { throw AmuxOrchestrationError.invalidValue("title") }
        guard !requestedBy.isEmpty else { throw AmuxOrchestrationError.invalidValue("requested_by") }
        let gate = AmuxOrchestrationGate(
            id: UUID(),
            taskID: taskID,
            title: title,
            requestedBy: requestedBy,
            status: .pending,
            resolvedBy: nil,
            resolutionNote: nil,
            createdAt: Date(),
            resolvedAt: nil
        )
        try append(Record(kind: .gate, message: nil, task: nil, gate: gate, heartbeat: nil))
        gates[gate.id] = gate
        compactIfNeeded()
        return gate
    }

    func resolveGate(
        id: UUID,
        status: AmuxOrchestrationGateStatus,
        resolvedBy: String,
        note: String?
    ) throws -> AmuxOrchestrationGate {
        guard status != .pending else { throw AmuxOrchestrationError.invalidValue("status") }
        guard !resolvedBy.isEmpty else { throw AmuxOrchestrationError.invalidValue("resolved_by") }
        guard var gate = gates[id] else { throw AmuxOrchestrationError.notFound("gate_id") }
        guard gate.status == .pending else { throw AmuxOrchestrationError.invalidValue("gate_already_resolved") }
        gate.status = status
        gate.resolvedBy = resolvedBy
        gate.resolutionNote = note
        gate.resolvedAt = Date()
        try append(Record(kind: .gate, message: nil, task: nil, gate: gate, heartbeat: nil))
        gates[id] = gate
        compactIfNeeded()
        return gate
    }

    func listGates(taskID: UUID? = nil) -> [AmuxOrchestrationGate] {
        gates.values
            .filter { taskID == nil || $0.taskID == taskID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func recordHeartbeat(worker: String, taskID: UUID?, state: String) throws -> AmuxOrchestrationHeartbeat {
        guard !worker.isEmpty else { throw AmuxOrchestrationError.invalidValue("worker") }
        if let taskID, tasks[taskID] == nil { throw AmuxOrchestrationError.notFound("task_id") }
        let heartbeat = AmuxOrchestrationHeartbeat(
            worker: worker,
            taskID: taskID,
            state: state.isEmpty ? "idle" : state,
            timestamp: Date()
        )
        // Heartbeats are high-frequency and collapse to latest-per-worker, so they are
        // never appended to the log. They are persisted only as part of a compaction
        // snapshot (latest per worker), keeping the on-disk log bounded.
        heartbeats[worker] = heartbeat
        return heartbeat
    }

    private func snapshot(
        for task: AmuxOrchestrationTask,
        staleAfter: Duration = .seconds(90)
    ) -> AmuxOrchestrationTaskSnapshot {
        let dependencyStatuses = Dictionary(uniqueKeysWithValues: task.dependencyIDs.compactMap { id in
            tasks[id].map { (id, $0.status) }
        })
        let taskGates = gates.values.filter { $0.taskID == task.id }.sorted { $0.createdAt < $1.createdAt }
        let heartbeat = task.assignee.flatMap { heartbeats[$0] }.flatMap { $0.taskID == task.id ? $0 : nil }
        let staleCutoff = Date().addingTimeInterval(-staleAfter.timeInterval)
        let dependenciesReady = dependencyStatuses.values.allSatisfy { $0 == .completed }
        let gatesReady = taskGates.allSatisfy { $0.status == .approved || $0.status == .cancelled }
        return AmuxOrchestrationTaskSnapshot(
            task: task,
            dependencyStatuses: dependencyStatuses,
            gates: taskGates,
            heartbeat: heartbeat,
            isRunnable: !task.status.isTerminal && dependenciesReady && gatesReady,
            isHeartbeatStale: task.status == .inProgress && (heartbeat?.timestamp ?? .distantPast) < staleCutoff
        )
    }

    private func append(_ record: Record) throws {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            var data = try encoder.encode(record)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: storageURL.path) {
                try data.write(to: storageURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: storageURL.path
                )
                persistedRecordCount += 1
                return
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
            let handle = try FileHandle(forWritingTo: storageURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            persistedRecordCount += 1
        } catch {
            throw AmuxOrchestrationError.persistence(String(describing: error))
        }
    }

    /// Number of messages retained in memory. Test/diagnostic accessor.
    var inMemoryMessageCount: Int { messages.count }

    /// Forces an immediate compaction pass regardless of thresholds. Test-only hook.
    func compactForTesting() { try? compact() }

    private var liveRecordCount: Int {
        tasks.count + gates.count + heartbeats.count + messages.count
    }

    private func compactIfNeeded() {
        guard Self.shouldCompact(
            persistedRecordCount: persistedRecordCount,
            liveRecordCount: liveRecordCount,
            threshold: compactionRecordThreshold
        ) else { return }
        // Compaction is a best-effort maintenance rewrite; the mutation that triggered
        // it has already been persisted, so a failure here only leaves the log large.
        try? compact()
    }

    private func compact() throws {
        let count = try Self.writeSnapshot(
            to: storageURL,
            encoder: encoder,
            tasks: tasks,
            gates: gates,
            heartbeats: heartbeats,
            messages: messages,
            messageTail: maxInMemoryMessages
        )
        persistedRecordCount = count
    }

    private static func shouldCompact(
        persistedRecordCount: Int,
        liveRecordCount: Int,
        threshold: Int
    ) -> Bool {
        guard persistedRecordCount > threshold else { return false }
        // Only rewrite when the log is at least twice its live footprint, so a file that
        // genuinely holds that many live records is not rewritten on every append.
        return liveRecordCount * 2 < persistedRecordCount
    }

    /// Rewrites `storageURL` as a compact snapshot: the latest state of every task,
    /// gate, and heartbeat (collapsed per key) plus a bounded tail of recent messages.
    /// Returns the number of records written. `nonisolated static` so it is callable
    /// from `init` without actor-isolation hops.
    private static func writeSnapshot(
        to storageURL: URL,
        encoder: JSONEncoder,
        tasks: [UUID: AmuxOrchestrationTask],
        gates: [UUID: AmuxOrchestrationGate],
        heartbeats: [String: AmuxOrchestrationHeartbeat],
        messages: [AmuxOrchestrationMessage],
        messageTail: Int
    ) throws -> Int {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            var data = Data()
            var count = 0
            for task in tasks.values.sorted(by: { $0.createdAt < $1.createdAt }) {
                data.append(try encoder.encode(Record(kind: .task, message: nil, task: task, gate: nil, heartbeat: nil)))
                data.append(0x0A)
                count += 1
            }
            for gate in gates.values.sorted(by: { $0.createdAt < $1.createdAt }) {
                data.append(try encoder.encode(Record(kind: .gate, message: nil, task: nil, gate: gate, heartbeat: nil)))
                data.append(0x0A)
                count += 1
            }
            for heartbeat in heartbeats.values.sorted(by: { $0.worker < $1.worker }) {
                data.append(try encoder.encode(Record(kind: .heartbeat, message: nil, task: nil, gate: nil, heartbeat: heartbeat)))
                data.append(0x0A)
                count += 1
            }
            for message in messages.suffix(messageTail) {
                data.append(try encoder.encode(Record(kind: .message, message: message, task: nil, gate: nil, heartbeat: nil)))
                data.append(0x0A)
                count += 1
            }
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
            return count
        } catch {
            throw AmuxOrchestrationError.persistence(String(describing: error))
        }
    }

    private static func trim(_ messages: inout [AmuxOrchestrationMessage], to cap: Int) {
        if messages.count > cap {
            messages.removeFirst(messages.count - cap)
        }
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }

    private func matchingMessages(
        recipient: String,
        groups: Set<String>,
        afterSequence: Int64,
        limit: Int
    ) -> [AmuxOrchestrationMessage] {
        Array(messages.lazy.filter { message in
            guard message.sequence > afterSequence else { return false }
            return message.recipients.contains(recipient)
                || message.recipients.contains("*")
                || !groups.isDisjoint(with: message.groups)
        }.prefix(limit))
    }

    private func notifyMessageWaiters(matching message: AmuxOrchestrationMessage) {
        for waiter in messageWaiters.values where message.sequence > waiter.afterSequence {
            if message.recipients.contains(waiter.recipient)
                || message.recipients.contains("*")
                || !waiter.groups.isDisjoint(with: message.groups) {
                waiter.continuation.yield(())
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
