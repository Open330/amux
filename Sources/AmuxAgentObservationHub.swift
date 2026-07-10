import CmuxMuxa
import Foundation

/// Composes agent observation across daemons: the local muxad plus one
/// forwarded muxad per SSH host that currently has a live mirror.
///
/// The hub owns lifecycle only — each ``AmuxAgentStatusService`` still does
/// its own snapshot/subscribe/join — and answers the cross-daemon questions
/// (attend target, a workspace's agent pane) by asking every service.
/// ``reconcile()`` runs on every mirror-topology change: a host gaining its
/// first mirror gets a forwarder + service, a host losing its last one gets
/// both torn down.
@MainActor
final class AmuxAgentObservationHub {
    /// One remote host's observation pair: the socket forward and the
    /// status service reading through it.
    struct RemoteObserver {
        let forwarder: AmuxRemoteMuxaForwarder
        let service: AmuxAgentStatusService
    }

    private let localService: AmuxAgentStatusService
    /// The SSH hosts that should be observed right now (those with ≥1 live
    /// mirror) — injected so tests drive reconcile without a controller.
    private let sshHosts: @MainActor () -> [RemoteTmuxHost]
    /// Builds a host's forwarder + service pair (composition-root injected:
    /// the service needs host-scoped join closures and the alarm sink).
    private let makeRemoteObserver: @MainActor (RemoteTmuxHost) -> RemoteObserver

    private var remoteObservers: [String: RemoteObserver] = [:]
    private var started = false

    init(
        localService: AmuxAgentStatusService,
        sshHosts: @escaping @MainActor () -> [RemoteTmuxHost],
        makeRemoteObserver: @escaping @MainActor (RemoteTmuxHost) -> RemoteObserver
    ) {
        self.localService = localService
        self.sshHosts = sshHosts
        self.makeRemoteObserver = makeRemoteObserver
    }

    /// Starts local observation and reconciles remote observers (idempotent).
    func start() {
        guard !started else { return }
        started = true
        localService.start()
        reconcile()
    }

    /// Stops every service and forward.
    func stop() {
        started = false
        localService.stop()
        for (_, observer) in remoteObservers {
            teardown(observer)
        }
        remoteObservers = [:]
    }

    /// Diffs the wanted host set against running observers: starts a
    /// forwarder + service for newly mirrored hosts, tears down observers
    /// whose host has no mirror left. Safe to call spuriously.
    func reconcile() {
        guard started else { return }
        let wanted = Dictionary(
            sshHosts().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (hostId, observer) in remoteObservers where wanted[hostId] == nil {
            teardown(observer)
            remoteObservers[hostId] = nil
        }
        for (hostId, host) in wanted where remoteObservers[hostId] == nil {
            let observer = makeRemoteObserver(host)
            remoteObservers[hostId] = observer
            observer.service.start()
        }
    }

    /// The number of remote hosts currently observed (diagnostics/tests).
    var remoteObserverCount: Int { remoteObservers.count }

    /// The workspace (and tmux pane) of the agent blocked on the user the
    /// longest across every observed daemon — the attend jump target.
    func attendTarget() -> (workspace: Workspace, tmuxPane: Int?)? {
        let candidates = ([localService] + remoteObservers.values.map(\.service))
            .compactMap { $0.attendCandidate() }
        return candidates
            .min { $0.blockedSince < $1.blockedSince }
            .map { ($0.workspace, $0.tmuxPane) }
    }

    /// Every tracked agent in `workspaceId`, asking each daemon in turn (a
    /// workspace mirrors exactly one host, so at most one service resolves
    /// it) — the data behind the agent-details view.
    func agents(inWorkspace workspaceId: UUID) -> [MuxaAgent] {
        let local = localService.agents(inWorkspace: workspaceId)
        if !local.isEmpty { return local }
        for observer in remoteObservers.values {
            let agents = observer.service.agents(inWorkspace: workspaceId)
            if !agents.isEmpty { return agents }
        }
        return []
    }

    /// Tracked agents for a detached tmux session on `host`. Local observation
    /// is scoped to the dedicated amux server; SSH rows come from that host's
    /// active observer. The user's default local tmux server cannot be joined
    /// safely because muxad does not report which local server socket produced a
    /// session name.
    func agents(host: RemoteTmuxHost, inTmuxSession tmuxSession: String) -> [MuxaAgent] {
        switch host.kind {
        case .localAmux:
            return localService.agents(inTmuxSession: tmuxSession)
        case .localDefault:
            return []
        case .ssh:
            return remoteObservers[host.id]?.service.agents(inTmuxSession: tmuxSession) ?? []
        }
    }

    /// The tmux pane of `workspaceId`'s most relevant agent, asking each
    /// daemon in turn (a workspace mirrors exactly one host, so at most one
    /// service resolves it).
    func agentPane(inWorkspace workspaceId: UUID) -> Int? {
        if let pane = localService.agentPane(inWorkspace: workspaceId) {
            return pane
        }
        for observer in remoteObservers.values {
            if let pane = observer.service.agentPane(inWorkspace: workspaceId) {
                return pane
            }
        }
        return nil
    }

    private func teardown(_ observer: RemoteObserver) {
        observer.service.stop()
        // Synchronous (`stop()` is nonisolated) so the app-termination path
        // tears the `ssh -N` down for certain — a scheduled actor hop might
        // never run once the app is exiting.
        observer.forwarder.stop()
    }
}
