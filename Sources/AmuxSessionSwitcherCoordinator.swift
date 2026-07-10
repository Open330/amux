import Foundation
import Observation

/// Owns the cancellable, progressive lifecycle of the unified tmux session list.
@MainActor
@Observable
final class AmuxSessionSwitcherCoordinator {
    private(set) var items: [AmuxSessionSwitcherItem] = []
    private(set) var loadingHosts: [RemoteTmuxHost] = []
    private(set) var failedHosts: [RemoteTmuxHost] = []
    private(set) var hostCount = 0
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private let loader: (any AmuxSessionSwitcherLoading)?
    @ObservationIgnored private var hosts: [RemoteTmuxHost] = []
    @ObservationIgnored private var itemsByHostID: [String: [AmuxSessionSwitcherItem]] = [:]
    @ObservationIgnored private var loadTasksByHostID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var changeObservers: [UUID: AsyncStream<AmuxSessionSwitcherSnapshot>.Continuation] = [:]

    init(loader: (any AmuxSessionSwitcherLoading)?) {
        self.loader = loader
    }

    var isLoading: Bool { !loadingHosts.isEmpty }

    var snapshot: AmuxSessionSwitcherSnapshot {
        AmuxSessionSwitcherSnapshot(
            items: items,
            loadingHosts: loadingHosts,
            failedHosts: failedHosts,
            hostCount: hostCount,
            revision: revision
        )
    }

    /// Emits an immutable snapshot after each loading, success, failure, or cancellation transition.
    func changes() -> AsyncStream<AmuxSessionSwitcherSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeObservers[id] = nil }
            }
        }
    }

    func start(hosts: [RemoteTmuxHost]) {
        self.hosts = hosts
        beginLoading(preservingResults: false)
    }

    func refresh() {
        beginLoading(preservingResults: true)
    }

    func cancel() {
        generation &+= 1
        cancelLoadTasks()
        hosts = []
        itemsByHostID = [:]
        items = []
        loadingHosts = []
        failedHosts = []
        hostCount = 0
        publishChange()
    }

    private func beginLoading(preservingResults: Bool) {
        generation &+= 1
        let loadGeneration = generation
        cancelLoadTasks()

        let hostIDs = Set(hosts.map(\.id))
        if preservingResults {
            itemsByHostID = itemsByHostID.filter { hostIDs.contains($0.key) }
        } else {
            itemsByHostID = [:]
        }
        items = AmuxSessionSwitcherItem.ordered(itemsByHostID.values.flatMap { $0 })
        failedHosts = []
        loadingHosts = hosts
        hostCount = hosts.count
        publishChange()

        guard let loader else {
            failedHosts = hosts
            loadingHosts = []
            publishChange()
            return
        }

        for host in hosts {
            let task = Task { @MainActor [weak self, loader] in
                do {
                    let loadedItems = try await loader.load(host: host)
                    guard !Task.isCancelled else { return }
                    self?.receive(
                        .success(loadedItems),
                        for: host,
                        generation: loadGeneration
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.receive(.failure(error), for: host, generation: loadGeneration)
                }
            }
            loadTasksByHostID[host.id] = task
        }
    }

    private func receive(
        _ result: Result<[AmuxSessionSwitcherItem], any Error>,
        for host: RemoteTmuxHost,
        generation loadGeneration: UInt64
    ) {
        guard loadGeneration == generation else { return }
        loadTasksByHostID[host.id] = nil
        loadingHosts.removeAll { $0.id == host.id }

        switch result {
        case .success(let loadedItems):
            itemsByHostID[host.id] = loadedItems
            failedHosts.removeAll { $0.id == host.id }
        case .failure(let error):
            failedHosts.append(host)
            #if DEBUG
            cmuxDebugLog(
                "amux: session switcher could not list "
                    + "\(host.destination): \(String(describing: error))"
            )
            #endif
        }

        items = AmuxSessionSwitcherItem.ordered(itemsByHostID.values.flatMap { $0 })
        publishChange()
    }

    private func cancelLoadTasks() {
        for task in loadTasksByHostID.values {
            task.cancel()
        }
        loadTasksByHostID = [:]
    }

    private func publishChange() {
        revision &+= 1
        let snapshot = snapshot
        for continuation in changeObservers.values {
            continuation.yield(snapshot)
        }
    }
}
