import Foundation

actor AmuxOrchestrationStore {
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
    private var nextMessageSequence: Int64 = 1
    private var messages: [AmuxOrchestrationMessage] = []
    private var tasks: [UUID: AmuxOrchestrationTask] = [:]
    private var gates: [UUID: AmuxOrchestrationGate] = [:]
    private var heartbeats: [String: AmuxOrchestrationHeartbeat] = [:]
    private let encoder: JSONEncoder

    init(storageURL: URL = AmuxOrchestrationStore.defaultStorageURL) {
        self.storageURL = storageURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL), !data.isEmpty else { return }
        for line in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else { continue }
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(boundedWait))

        while true {
            let available = messages.lazy.filter { message in
                guard message.sequence > afterSequence else { return false }
                return message.recipients.contains(recipient)
                    || message.recipients.contains("*")
                    || !groups.isDisjoint(with: message.groups)
            }
            if !available.isEmpty || boundedWait == 0 || clock.now >= deadline || Task.isCancelled {
                return Array(available.prefix(boundedLimit))
            }
            try? await Task.sleep(for: .milliseconds(75))
        }
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
        try append(Record(kind: .heartbeat, message: nil, task: nil, gate: nil, heartbeat: heartbeat))
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
        } catch {
            throw AmuxOrchestrationError.persistence(String(describing: error))
        }
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
