import Foundation

extension TerminalController {
    nonisolated func v2AmuxMessageSend(id: Any?, params: [String: Any]) -> String {
        guard let typeValue = params["type"] as? String,
              let type = AmuxOrchestrationMessageType(rawValue: typeValue),
              let sender = Self.amuxNonemptyString(params["sender"]),
              let body = Self.amuxNonemptyString(params["body"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("type/sender/body"))
        }
        let recipients = Self.amuxStringList(params, singular: "recipient", plural: "recipients")
        let groups = Self.amuxStringList(params, singular: "group", plural: "groups")
        let taskID = Self.amuxOptionalUUID(params["task_id"])
        if params["task_id"] != nil, taskID == nil {
            return v2AmuxOrchestrationError(id: id, .invalidValue("task_id"))
        }
        guard let metadata = Self.amuxStringDictionary(params["metadata"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("metadata"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            do {
                let message = try await self.amuxOrchestrationStore.sendMessage(
                    type: type,
                    sender: sender,
                    recipients: recipients,
                    groups: groups,
                    taskID: taskID,
                    body: body,
                    metadata: metadata
                )
                return .ok(["message": Self.amuxMessagePayload(message)])
            } catch {
                return Self.amuxOrchestrationResult(error)
            }
        }
    }

    nonisolated func v2AmuxMessageCheck(id: Any?, params: [String: Any]) -> String {
        guard let recipient = Self.amuxNonemptyString(params["recipient"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("recipient"))
        }
        let groups = Set(Self.amuxStringList(params, singular: "group", plural: "groups"))
        let afterSequence = Self.amuxInt64(params["after_sequence"]) ?? 0
        let limit = Self.amuxInt(params["limit"]) ?? 50
        let waitMilliseconds = Self.amuxInt(params["wait_ms"]) ?? 0
        guard afterSequence >= 0, (1...200).contains(limit), (0...300_000).contains(waitMilliseconds) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("after_sequence/limit/wait_ms"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: TimeInterval(waitMilliseconds) / 1_000 + 5) {
            let messages = await self.amuxOrchestrationStore.checkMessages(
                recipient: recipient,
                groups: groups,
                afterSequence: afterSequence,
                limit: limit,
                waitMilliseconds: waitMilliseconds
            )
            return .ok([
                "messages": messages.map(Self.amuxMessagePayload),
                "cursor": messages.last?.sequence ?? afterSequence,
            ])
        }
    }

    nonisolated func v2AmuxTaskCreate(id: Any?, params: [String: Any]) -> String {
        guard let title = Self.amuxNonemptyString(params["title"]),
              let creator = Self.amuxNonemptyString(params["creator"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("title/creator"))
        }
        guard let dependencies = Self.amuxUUIDList(params["dependency_ids"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("dependency_ids"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            do {
                let snapshot = try await self.amuxOrchestrationStore.createTask(
                    title: title,
                    details: params["details"] as? String,
                    creator: creator,
                    assignee: params["assignee"] as? String,
                    dependencyIDs: dependencies,
                    baseRevision: params["base_revision"] as? String,
                    baseDistance: Self.amuxInt(params["base_distance"])
                )
                return .ok(["task": Self.amuxTaskPayload(snapshot)])
            } catch {
                return Self.amuxOrchestrationResult(error)
            }
        }
    }

    nonisolated func v2AmuxTaskList(id: Any?, params: [String: Any]) -> String {
        let status: AmuxOrchestrationTaskStatus?
        if let value = params["status"] as? String {
            guard let parsed = AmuxOrchestrationTaskStatus(rawValue: value) else {
                return v2AmuxOrchestrationError(id: id, .invalidValue("status"))
            }
            status = parsed
        } else {
            status = nil
        }
        let staleAfterSeconds = Self.amuxInt(params["stale_after_seconds"]) ?? 90
        guard (15...3_600).contains(staleAfterSeconds) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("stale_after_seconds"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            let snapshots = await self.amuxOrchestrationStore.taskSnapshots(
                status: status,
                assignee: params["assignee"] as? String,
                staleAfter: .seconds(staleAfterSeconds)
            )
            return .ok(["tasks": snapshots.map(Self.amuxTaskPayload)])
        }
    }

    nonisolated func v2AmuxTaskUpdate(id: Any?, params: [String: Any]) -> String {
        guard let taskID = Self.amuxOptionalUUID(params["task_id"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("task_id"))
        }
        let status: AmuxOrchestrationTaskStatus?
        if let value = params["status"] as? String {
            guard let parsed = AmuxOrchestrationTaskStatus(rawValue: value) else {
                return v2AmuxOrchestrationError(id: id, .invalidValue("status"))
            }
            status = parsed
        } else {
            status = nil
        }
        guard status != nil || params.keys.contains("assignee") || params.keys.contains("details") else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("status/assignee/details"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            do {
                let snapshot = try await self.amuxOrchestrationStore.updateTask(
                    id: taskID,
                    status: status,
                    assignee: params["assignee"] as? String,
                    details: params["details"] as? String
                )
                return .ok(["task": Self.amuxTaskPayload(snapshot)])
            } catch {
                return Self.amuxOrchestrationResult(error)
            }
        }
    }

    nonisolated func v2AmuxGateCreate(id: Any?, params: [String: Any]) -> String {
        guard let taskID = Self.amuxOptionalUUID(params["task_id"]),
              let title = Self.amuxNonemptyString(params["title"]),
              let requestedBy = Self.amuxNonemptyString(params["requested_by"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("task_id/title/requested_by"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            do {
                let gate = try await self.amuxOrchestrationStore.createGate(
                    taskID: taskID,
                    title: title,
                    requestedBy: requestedBy
                )
                return .ok(["gate": Self.amuxGatePayload(gate)])
            } catch {
                return Self.amuxOrchestrationResult(error)
            }
        }
    }

    nonisolated func v2AmuxGateList(id: Any?, params: [String: Any]) -> String {
        let taskID = Self.amuxOptionalUUID(params["task_id"])
        if params["task_id"] != nil, taskID == nil {
            return v2AmuxOrchestrationError(id: id, .invalidValue("task_id"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            let gates = await self.amuxOrchestrationStore.listGates(taskID: taskID)
            return .ok(["gates": gates.map(Self.amuxGatePayload)])
        }
    }

    nonisolated func v2AmuxGateResolve(id: Any?, params: [String: Any]) -> String {
        guard let gateID = Self.amuxOptionalUUID(params["gate_id"]),
              let statusValue = params["status"] as? String,
              let status = AmuxOrchestrationGateStatus(rawValue: statusValue),
              status != .pending,
              let resolvedBy = Self.amuxNonemptyString(params["resolved_by"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("gate_id/status/resolved_by"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            do {
                let gate = try await self.amuxOrchestrationStore.resolveGate(
                    id: gateID,
                    status: status,
                    resolvedBy: resolvedBy,
                    note: params["note"] as? String
                )
                return .ok(["gate": Self.amuxGatePayload(gate)])
            } catch {
                return Self.amuxOrchestrationResult(error)
            }
        }
    }

    nonisolated func v2AmuxHeartbeat(id: Any?, params: [String: Any]) -> String {
        guard let worker = Self.amuxNonemptyString(params["worker"]) else {
            return v2AmuxOrchestrationError(id: id, .invalidValue("worker"))
        }
        let taskID = Self.amuxOptionalUUID(params["task_id"])
        if params["task_id"] != nil, taskID == nil {
            return v2AmuxOrchestrationError(id: id, .invalidValue("task_id"))
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 15) {
            do {
                let heartbeat = try await self.amuxOrchestrationStore.recordHeartbeat(
                    worker: worker,
                    taskID: taskID,
                    state: (params["state"] as? String) ?? "idle"
                )
                return .ok(["heartbeat": Self.amuxHeartbeatPayload(heartbeat)])
            } catch {
                return Self.amuxOrchestrationResult(error)
            }
        }
    }

    private nonisolated func v2AmuxOrchestrationError(id: Any?, _ error: AmuxOrchestrationError) -> String {
        switch Self.amuxOrchestrationResult(error) {
        case .ok:
            return v2Error(
                id: id,
                code: "orchestration_error",
                message: String(localized: "socket.amux.orchestration.failed", defaultValue: "Orchestration request failed")
            )
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    private nonisolated static func amuxOrchestrationResult(_ error: Error) -> V2CallResult {
        guard let error = error as? AmuxOrchestrationError else {
            return .err(
                code: "orchestration_error",
                message: String(localized: "socket.amux.orchestration.failed", defaultValue: "Orchestration request failed"),
                data: ["detail": String(describing: error)]
            )
        }
        let message: String
        var data: [String: Any] = [:]
        switch error {
        case .invalidValue(let field):
            message = String(localized: "socket.amux.orchestration.invalidParams", defaultValue: "Invalid orchestration parameters")
            data["field"] = field
        case .notFound(let field):
            message = String(localized: "socket.amux.orchestration.notFound", defaultValue: "Orchestration item was not found")
            data["field"] = field
        case .dependencyNotReady(let ids):
            message = String(localized: "socket.amux.orchestration.dependenciesPending", defaultValue: "Task dependencies are not complete")
            data["dependency_ids"] = ids.map(\.uuidString)
        case .gateNotReady(let ids):
            message = String(localized: "socket.amux.orchestration.gatesPending", defaultValue: "Task decision gates are not approved")
            data["gate_ids"] = ids.map(\.uuidString)
        case .staleBase(let distance, let maximum):
            message = String(localized: "socket.amux.orchestration.staleBase", defaultValue: "Task base revision is too far behind")
            data["base_distance"] = distance
            data["maximum_distance"] = maximum
        case .persistence(let detail):
            message = String(localized: "socket.amux.orchestration.persistenceFailed", defaultValue: "Orchestration state could not be saved")
            data["detail"] = detail
        }
        return .err(code: error.code, message: message, data: data)
    }

    private nonisolated static func amuxMessagePayload(_ message: AmuxOrchestrationMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "sequence": message.sequence,
            "id": message.id.uuidString,
            "type": message.type.rawValue,
            "sender": message.sender,
            "recipients": message.recipients,
            "groups": message.groups,
            "body": message.body,
            "metadata": message.metadata,
            "created_at": amuxISO8601(message.createdAt),
        ]
        if let taskID = message.taskID { payload["task_id"] = taskID.uuidString }
        return payload
    }

    private nonisolated static func amuxTaskPayload(_ snapshot: AmuxOrchestrationTaskSnapshot) -> [String: Any] {
        let task = snapshot.task
        var payload: [String: Any] = [
            "id": task.id.uuidString,
            "title": task.title,
            "creator": task.creator,
            "status": task.status.rawValue,
            "dependency_ids": task.dependencyIDs.map(\.uuidString),
            "dependency_statuses": Dictionary(uniqueKeysWithValues: snapshot.dependencyStatuses.map { ($0.key.uuidString, $0.value.rawValue) }),
            "gates": snapshot.gates.map(amuxGatePayload),
            "runnable": snapshot.isRunnable,
            "heartbeat_stale": snapshot.isHeartbeatStale,
            "created_at": amuxISO8601(task.createdAt),
            "updated_at": amuxISO8601(task.updatedAt),
        ]
        if let details = task.details { payload["details"] = details }
        if let assignee = task.assignee { payload["assignee"] = assignee }
        if let baseRevision = task.baseRevision { payload["base_revision"] = baseRevision }
        if let baseDistance = task.baseDistance { payload["base_distance"] = baseDistance }
        if let heartbeat = snapshot.heartbeat { payload["heartbeat"] = amuxHeartbeatPayload(heartbeat) }
        return payload
    }

    private nonisolated static func amuxGatePayload(_ gate: AmuxOrchestrationGate) -> [String: Any] {
        var payload: [String: Any] = [
            "id": gate.id.uuidString,
            "task_id": gate.taskID.uuidString,
            "title": gate.title,
            "requested_by": gate.requestedBy,
            "status": gate.status.rawValue,
            "created_at": amuxISO8601(gate.createdAt),
        ]
        if let resolvedBy = gate.resolvedBy { payload["resolved_by"] = resolvedBy }
        if let note = gate.resolutionNote { payload["note"] = note }
        if let resolvedAt = gate.resolvedAt { payload["resolved_at"] = amuxISO8601(resolvedAt) }
        return payload
    }

    private nonisolated static func amuxHeartbeatPayload(_ heartbeat: AmuxOrchestrationHeartbeat) -> [String: Any] {
        var payload: [String: Any] = [
            "worker": heartbeat.worker,
            "state": heartbeat.state,
            "timestamp": amuxISO8601(heartbeat.timestamp),
        ]
        if let taskID = heartbeat.taskID { payload["task_id"] = taskID.uuidString }
        return payload
    }

    private nonisolated static func amuxNonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func amuxStringList(
        _ params: [String: Any],
        singular: String,
        plural: String
    ) -> [String] {
        var values = (params[plural] as? [String]) ?? []
        if let value = params[singular] as? String { values.append(value) }
        return values
    }

    private nonisolated static func amuxOptionalUUID(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private nonisolated static func amuxUUIDList(_ value: Any?) -> [UUID]? {
        guard let value else { return [] }
        guard let strings = value as? [String] else { return nil }
        let ids = strings.compactMap(UUID.init(uuidString:))
        return ids.count == strings.count ? ids : nil
    }

    private nonisolated static func amuxStringDictionary(_ value: Any?) -> [String: String]? {
        guard let value else { return [:] }
        guard let dictionary = value as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            guard let value = value as? String else { return nil }
            result[key] = value
        }
        return result
    }

    private nonisolated static func amuxInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private nonisolated static func amuxInt64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        return (value as? NSNumber)?.int64Value
    }

    private nonisolated static func amuxISO8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
