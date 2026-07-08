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
    /// Sends `text` into `workspace`'s mirrored session — to its most
    /// relevant agent's pane when muxa tracks one, else the session's
    /// prompt-target pane — without attaching or changing focus. Shared
    /// path for the palette composer and the `amux.send_prompt` socket RPC.
    @discardableResult
    func amuxSendPrompt(_ text: String, to workspace: Workspace) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let agentPane = amuxAgentStatusService.agentPane(inWorkspace: workspace.id)
        return remoteTmuxController.sendPromptToMirror(
            workspaceId: workspace.id,
            tmuxPane: agentPane,
            text: trimmed
        )
    }

    /// Modal prompt composer for ``amuxSendPrompt(_:to:)`` (the palette /
    /// menu entrypoint). Multi-line text view; Send is the default button.
    func amuxPresentPromptComposer(for workspace: Workspace) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "amux.composer.title",
            defaultValue: "Send Prompt to Agent"
        )
        alert.informativeText = workspace.customTitle ?? ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 88))
        let textView = NSTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "amux.composer.send", defaultValue: "Send"))
        alert.addButton(withTitle: String(localized: "amux.composer.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !amuxSendPrompt(textView.string, to: workspace) {
            NSSound.beep()
        }
    }

    /// Attend: selects the workspace (and focuses the tmux pane) of the
    /// agent that has been blocked on the user the longest. Shared action
    /// path for the Debug menu item and the `amux.attend` socket RPC.
    /// Returns `false` when no tracked agent needs attention or none
    /// resolves to a workspace.
    /// Finds the tab manager (and workspace) owning `workspaceId` across the
    /// main window and every additional main-window context.
    func amuxWorkspace(withId workspaceId: UUID) -> (manager: TabManager, workspace: Workspace)? {
        if let manager = tabManager,
           let workspace = manager.tabs.first(where: { $0.id == workspaceId }) {
            return (manager, workspace)
        }
        for context in mainWindowContexts.values {
            if let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }) {
                return (context.tabManager, workspace)
            }
        }
        return nil
    }

    @discardableResult
    func amuxAttend() -> Bool {
        guard let target = amuxAgentStatusService.attendTarget() else { return false }
        guard let (manager, _) = amuxWorkspace(withId: target.workspace.id) else { return false }
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
