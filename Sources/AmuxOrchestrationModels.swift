import Foundation

enum AmuxOrchestrationMessageType: String, Codable, CaseIterable, Sendable {
    case status
    case dispatch
    case workerDone = "worker_done"
    case mergeReady = "merge_ready"
    case escalation
    case handoff
    case decisionGate = "decision_gate"
    case heartbeat
}

struct AmuxOrchestrationMessage: Codable, Equatable, Sendable {
    let sequence: Int64
    let id: UUID
    let type: AmuxOrchestrationMessageType
    let sender: String
    let recipients: [String]
    let groups: [String]
    let taskID: UUID?
    let body: String
    let metadata: [String: String]
    let createdAt: Date
}

enum AmuxOrchestrationTaskStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress = "in_progress"
    case blocked
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .pending, .inProgress, .blocked:
            false
        }
    }
}

struct AmuxOrchestrationTask: Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var details: String?
    let creator: String
    var assignee: String?
    var status: AmuxOrchestrationTaskStatus
    let dependencyIDs: [UUID]
    let baseRevision: String?
    let baseDistance: Int?
    let createdAt: Date
    var updatedAt: Date
}

enum AmuxOrchestrationGateStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case approved
    case rejected
    case cancelled
}

struct AmuxOrchestrationGate: Codable, Equatable, Sendable {
    let id: UUID
    let taskID: UUID
    let title: String
    let requestedBy: String
    var status: AmuxOrchestrationGateStatus
    var resolvedBy: String?
    var resolutionNote: String?
    let createdAt: Date
    var resolvedAt: Date?
}

struct AmuxOrchestrationHeartbeat: Codable, Equatable, Sendable {
    let worker: String
    var taskID: UUID?
    var state: String
    var timestamp: Date
}

enum AmuxOrchestrationError: Error, Equatable, Sendable {
    case invalidValue(String)
    case notFound(String)
    case dependencyNotReady([UUID])
    case gateNotReady([UUID])
    case staleBase(distance: Int, maximum: Int)
    case persistence(String)

    var code: String {
        switch self {
        case .invalidValue: "invalid_params"
        case .notFound: "not_found"
        case .dependencyNotReady: "dependency_not_ready"
        case .gateNotReady: "gate_not_ready"
        case .staleBase: "stale_base"
        case .persistence: "persistence_error"
        }
    }
}

struct AmuxOrchestrationTaskSnapshot: Equatable, Sendable {
    let task: AmuxOrchestrationTask
    let dependencyStatuses: [UUID: AmuxOrchestrationTaskStatus]
    let gates: [AmuxOrchestrationGate]
    let heartbeat: AmuxOrchestrationHeartbeat?
    let isRunnable: Bool
    let isHeartbeatStale: Bool
}
