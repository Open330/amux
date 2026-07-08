import AppKit

extension AppDelegate {
    /// Builds the muxa agent-status service, joining muxad rows to amux
    /// local-engine mirror workspaces (composition root wiring; the service
    /// itself takes closures so it stays testable without an AppDelegate).
    func makeAmuxAgentStatusService() -> AmuxAgentStatusService {
        AmuxAgentStatusService(
            workspaceForSession: { [weak self] sessionName in
                self?.remoteTmuxController.localMirrorWorkspace(sessionName: sessionName)
            },
            workspaceForPane: { [weak self] paneId in
                self?.remoteTmuxController.localMirrorWorkspace(containingPane: paneId)
            }
        )
    }

    /// Launch-time reconcile for the amux local engine: any session left on
    /// the dedicated local server (detach-by-default means the server
    /// outlives the app) is re-mirrored as a workspace, so a restart brings
    /// the user's sessions back without a manual attach. A missing server or
    /// empty session list is a silent no-op (`discoverMirrorSessions` with
    /// `createIfEmpty: false` never creates sessions).
    func reconcileLocalAmuxSessionsAtLaunch() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.remoteTmuxController.mirrorHost(host: .amuxLocal())
            } catch {
                #if DEBUG
                cmuxDebugLog("amux: launch reconcile failed: \(error)")
                #endif
            }
        }
    }

    /// Debug entrypoint for the amux Phase 0 spike: mirrors a local tmux
    /// session into a workspace through the RemoteTmux control-mode stack.
    ///
    /// Attach-or-creates the `amux-spike` session on the dedicated `-L amux`
    /// server socket (see ``RemoteTmuxHost/amuxLocal()``), so repeated
    /// invocations after the mirror workspace is closed re-attach to the same
    /// live session — the detach-survives-the-app property under test.
    /// Attend: selects the workspace (and focuses the tmux pane) of the
    /// agent that has been blocked on the user the longest. Shared action
    /// path for the Debug menu item and the `amux.attend` socket RPC.
    /// Returns `false` when no tracked agent needs attention or none
    /// resolves to a workspace.
    @discardableResult
    func amuxAttend() -> Bool {
        guard let target = amuxAgentStatusService.attendTarget() else { return false }
        let manager: TabManager?
        if tabManager?.tabs.contains(where: { $0.id == target.workspace.id }) == true {
            manager = tabManager
        } else {
            manager = mainWindowContexts.values.map(\.tabManager)
                .first { $0.tabs.contains(where: { $0.id == target.workspace.id }) }
        }
        guard let manager else { return false }
        manager.selectWorkspace(target.workspace)
        if let pane = target.tmuxPane {
            remoteTmuxController.focusMirrorPane(workspaceId: target.workspace.id, tmuxPane: pane)
        }
        return true
    }

    /// Menu entry for ``amuxAttend()``.
    @objc func amuxAttendAction(_ sender: Any?) {
        _ = amuxAttend()
    }

    @objc func openDebugAmuxLocalTmuxMirror(_ sender: Any?) {
        guard let manager = tabManager else { return }
        do {
            try remoteTmuxController.mirrorLocalAmuxSession(into: manager)
        } catch {
            #if DEBUG
            cmuxDebugLog("amux: local tmux mirror failed: \(error)")
            #endif
        }
    }
}
