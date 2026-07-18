import Foundation
import Observation
import OSLog

/// Owns the cancellable, progressive lifecycle of the unified tmux session list.
///
/// Consumers observe the `@Observable` state directly (`items`, `loadingHosts`,
/// `failedHosts`, `hostCount`, `revision`); `revision` bumps on every loading,
/// success, failure, or cancellation transition so a SwiftUI fingerprint can
/// re-derive its candidates. There is no separate change stream — production and
/// tests read the same observable path.
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
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel in-flight
    // loads. Every other access is main-actor serialized, and by the time deinit
    // runs no other reference to the coordinator survives, so there is no
    // concurrent mutation to guard against.
    @ObservationIgnored private nonisolated(unsafe) var loadTasksByHostID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation: UInt64 = 0

    nonisolated private static let logger = Logger(
        subsystem: "com.open330.amux",
        category: "AmuxSessionSwitcher"
    )

    init(loader: (any AmuxSessionSwitcherLoading)?) {
        self.loader = loader
    }

    deinit {
        cancelLoadTasks()
    }

    var isLoading: Bool { !loadingHosts.isEmpty }

    func start(hosts: [RemoteTmuxHost]) {
        self.hosts = Self.deduplicated(hosts)
        beginLoading(preservingResults: false)
    }

    /// Reloads the current hosts, keeping already-loaded rows visible. This is a
    /// no-op when there are no hosts (e.g. after `cancel()` clears them), so a
    /// stray refresh can never publish an empty list over a live one.
    func refresh() {
        guard !hosts.isEmpty else { return }
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
        // ContentView re-sorts every candidate with an isOpen/isCurrent-aware
        // comparator, so ordering the rows here would just be discarded.
        items = itemsByHostID.values.flatMap { $0 }
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
            Self.logger.error(
                "session switcher could not list host [\(host.connectionHash, privacy: .public)]: \(String(describing: error), privacy: .public)"
            )
            #if DEBUG
            cmuxDebugLog(
                "amux: session switcher could not list "
                    + "\(host.destination): \(String(describing: error))"
            )
            #endif
        }

        // See `beginLoading`: ContentView owns the final ordering.
        items = itemsByHostID.values.flatMap { $0 }
        publishChange()
    }

    private nonisolated func cancelLoadTasks() {
        for task in loadTasksByHostID.values {
            task.cancel()
        }
        loadTasksByHostID = [:]
    }

    /// Removes duplicate hosts (same `id`) while preserving first-seen order, so a
    /// repeated endpoint can't spawn a second load task whose completion flips
    /// `isLoading` while a sibling task is still running.
    private static func deduplicated(_ hosts: [RemoteTmuxHost]) -> [RemoteTmuxHost] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0.id).inserted }
    }

    /// Bumps `revision` so SwiftUI observers re-derive their session-switcher
    /// candidates from the coordinator's `@Observable` state.
    private func publishChange() {
        revision &+= 1
    }
}
