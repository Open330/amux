import AppKit
import CmuxMuxa

extension AppDelegate {
    /// Builds the agent-observation hub: the local muxad status service plus
    /// a factory for per-SSH-host observers (socket forwarder + status
    /// service joined against that host's mirrors). Composition-root wiring;
    /// the hub and services take closures so they stay testable without an
    /// AppDelegate.
    func makeAmuxAgentObservationHub() -> AmuxAgentObservationHub {
        // One gate across every daemon: agent session ids are globally
        // unique, and a single episode memory keeps local + remote sinks
        // consistent.
        let alarmGate = AmuxAgentAlarmGate()
        let onTransition: @MainActor (MuxaTransition, Workspace?) -> Void = { [weak self] transition, workspace in
            // The gate sees every pass (joined or not) so episode memory
            // stays fresh, but only a joined attention pass consumes the
            // episode — an unjoined one must alarm on a later joinable pass.
            guard let self,
                  let alarm = alarmGate.alarm(for: transition, joined: workspace != nil),
                  let workspace else { return }
            self.amuxDeliverAgentAlarm(alarm, workspace: workspace)
        }
        let localService = AmuxAgentStatusService(
            workspaceForSession: { [weak self] sessionName in
                self?.remoteTmuxController.localMirrorWorkspace(sessionName: sessionName)
            },
            workspaceForPane: { [weak self] paneId in
                self?.remoteTmuxController.localMirrorWorkspace(containingPane: paneId)
            },
            onTransition: onTransition
        )
        return AmuxAgentObservationHub(
            localService: localService,
            sshHosts: { [weak self] in
                self?.remoteTmuxController.activeSSHMirrorHosts() ?? []
            },
            makeRemoteObserver: { [weak self] host in
                let forwarder = AmuxRemoteMuxaForwarder(host: host)
                let hostId = host.id
                let service = AmuxAgentStatusService(
                    client: MuxaClient(address: MuxaSocketAddress(path: forwarder.localSocketPath)),
                    workspaceForSession: { [weak self] sessionName in
                        self?.remoteTmuxController.mirrorWorkspace(hostId: hostId, sessionName: sessionName)
                    },
                    workspaceForPane: { [weak self] paneId in
                        self?.remoteTmuxController.mirrorWorkspace(hostId: hostId, containingPane: paneId)
                    },
                    prepareConnection: { try await forwarder.ensureForward() },
                    onTransition: onTransition
                )
                return AmuxAgentObservationHub.RemoteObserver(forwarder: forwarder, service: service)
            }
        )
    }

    /// Delivers a gated agent alarm (see ``AmuxAgentAlarmGate``) into the
    /// notification pipeline as a workspace-scoped notification, so remote
    /// agents alert on this Mac instead of only on the remote host.
    func amuxDeliverAgentAlarm(_ alarm: AmuxAgentAlarm, workspace: Workspace) {
        guard let notificationStore else { return }
        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: nil,
            title: alarm.title,
            subtitle: workspace.customTitle ?? "",
            body: alarm.body,
            cooldownKey: alarm.cooldownKey,
            cooldownInterval: alarm.cooldownInterval
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
    /// Installs the opt-in muxad LaunchAgent so agent observation outlives
    /// the app — but defers to an already-running muxad (the user's own
    /// daemon) instead of starting a competing one. Reports the outcome as a
    /// modal so the user sees why it did or didn't install.
    func amuxInstallMuxadAgent() {
        Task { @MainActor in
            let running = await MuxaClient().isReachable()
            let agent = AmuxMuxadLaunchAgent()
            let result = agent.install(
                muxadPath: RemoteTmuxHost.bundledMuxadPath(),
                daemonAlreadyRunning: running
            )
            let alert = NSAlert()
            alert.messageText = String(localized: "amux.daemon.title", defaultValue: "amux Background Daemon")
            switch result {
            case .installed:
                alert.informativeText = String(
                    localized: "amux.daemon.installed",
                    defaultValue: "Installed. muxad now runs in the background and keeps observing your agents even when amux is closed."
                )
            case .deferredToRunningDaemon:
                alert.informativeText = String(
                    localized: "amux.daemon.deferred",
                    defaultValue: "A muxad is already running, so amux will use it. No background agent was installed."
                )
            case .noBundledDaemon:
                alert.informativeText = String(
                    localized: "amux.daemon.noBundled",
                    defaultValue: "This build has no bundled muxad. Run a release build or start muxad yourself."
                )
            case .failed(let detail):
                alert.informativeText = String(
                    localized: "amux.daemon.failed",
                    defaultValue: "Could not install the background daemon."
                ) + "\n\(detail)"
            }
            alert.runModal()
        }
    }

    /// Removes the muxad LaunchAgent (does not touch a manually-run muxad).
    func amuxUninstallMuxadAgent() {
        AmuxMuxadLaunchAgent().uninstall()
        let alert = NSAlert()
        alert.messageText = String(localized: "amux.daemon.title", defaultValue: "amux Background Daemon")
        alert.informativeText = String(
            localized: "amux.daemon.uninstalled",
            defaultValue: "Removed amux's background daemon. A muxad you started yourself is left running."
        )
        alert.runModal()
    }

    /// Whether ⌘N (the new-terminal-workspace action) creates an amux
    /// tmux-backed workspace instead of a plain local one. Persisted, default
    /// off during alpha so the dogfood/default behavior is unchanged until
    /// opted in. Toggled from the Command Palette.
    static let newWorkspaceTmuxBackedDefaultsKey = "amux.newWorkspace.tmuxBacked"
    var amuxNewWorkspaceUsesTmux: Bool {
        get { UserDefaults.standard.bool(forKey: Self.newWorkspaceTmuxBackedDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.newWorkspaceTmuxBackedDefaultsKey) }
    }

    /// Creates a fresh amux tmux-backed workspace (the headline "new
    /// workspace = tmux session" action) in `preferredManager` (or the key
    /// window's) and selects it. Shared path for the Command Palette / menu /
    /// `amux.new_session` RPC and the ⌘N redirect.
    func amuxCreateWorkspace(in preferredManager: TabManager? = nil) {
        guard let manager = preferredManager ?? tabManager else { NSSound.beep(); return }
        Task { @MainActor in
            do {
                let name = try await self.remoteTmuxController.createLocalAmuxWorkspace(into: manager)
                if let workspace = self.remoteTmuxController.localMirrorWorkspace(sessionName: name) {
                    manager.selectWorkspace(workspace)
                }
            } catch {
                NSSound.beep()
                #if DEBUG
                cmuxDebugLog("amux: create workspace failed: \(error)")
                #endif
            }
        }
    }

    /// Presents a picker of detached amux sessions (sessions on the local
    /// server not currently mirrored) and mirrors + selects the chosen one.
    /// No detached sessions → a brief informational alert.
    func amuxPresentDetachedSessionPicker() {
        guard let manager = tabManager else { NSSound.beep(); return }
        Task { @MainActor in
            let sessions = (try? await self.remoteTmuxController.localAmuxSessions()) ?? []
            let detached = sessions.filter { !$0.mirrored }.map(\.session.name)
            let alert = NSAlert()
            guard !detached.isEmpty else {
                alert.messageText = String(
                    localized: "amux.detached.none.title",
                    defaultValue: "No Detached Sessions"
                )
                alert.informativeText = String(
                    localized: "amux.detached.none.body",
                    defaultValue: "Every amux tmux session is already open as a workspace."
                )
                alert.runModal()
                return
            }
            alert.messageText = String(
                localized: "amux.detached.pick.title",
                defaultValue: "Attach Detached Session"
            )
            for name in detached {
                alert.addButton(withTitle: name)
            }
            alert.addButton(withTitle: String(localized: "amux.detached.cancel", defaultValue: "Cancel"))
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < detached.count else { return }
            self.amuxAttachSession(named: detached[index], in: manager)
        }
    }

    /// Mirrors the detached amux session `name` into `manager` and selects
    /// it. Returns `false` when the mirror could not be created.
    @discardableResult
    func amuxAttachSession(named name: String, in manager: TabManager) -> Bool {
        do {
            try remoteTmuxController.mirrorSession(host: .amuxLocal(), sessionName: name, into: manager)
            if let workspace = remoteTmuxController.localMirrorWorkspace(sessionName: name) {
                manager.selectWorkspace(workspace)
            }
            return true
        } catch {
            #if DEBUG
            cmuxDebugLog("amux: attach detached session \(name) failed: \(error)")
            #endif
            return false
        }
    }

    /// Closes `workspace` AND kills its mirrored tmux session (the explicit
    /// opt-out of detach-by-default) — local engine and SSH hosts alike.
    /// Kills the session first so the subsequent tab close is a no-op mirror
    /// teardown, then removes the tab. Returns `false` when the workspace
    /// isn't a live mirror.
    @discardableResult
    func amuxCloseAndKillWorkspace(_ workspace: Workspace) -> Bool {
        guard remoteTmuxController.isMirrorWorkspace(workspace.id) else { return false }
        remoteTmuxController.handleWorkspaceClosed(workspaceId: workspace.id, forceKill: true)
        if let (manager, _) = amuxWorkspace(withId: workspace.id) {
            manager.closeWorkspace(workspace)
        }
        return true
    }

    /// Sends `text` into `workspace`'s mirrored session — to its most
    /// relevant agent's pane when muxa tracks one, else the session's
    /// prompt-target pane — without attaching or changing focus. Shared
    /// path for the palette composer and the `amux.send_prompt` socket RPC.
    @discardableResult
    func amuxSendPrompt(_ text: String, to workspace: Workspace) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let agentPane = amuxAgentObservation.agentPane(inWorkspace: workspace.id)
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

    /// Promotes a `waiting_choice` agent's numbered menu to a native sheet:
    /// captures the agent pane, parses the options, and presents a button
    /// per option (falling back to the free-text composer when nothing
    /// parses). Selecting an option sends its number (plus Enter) to the
    /// pane. The `workspace` should be the agent's mirror workspace.
    @MainActor
    func amuxPresentChoiceSheet(for workspace: Workspace) {
        let agentPane = amuxAgentObservation.agentPane(inWorkspace: workspace.id)
        Task { @MainActor in
            let text = await remoteTmuxController.captureMirrorPaneText(
                workspaceId: workspace.id,
                tmuxPane: agentPane
            )
            let choices = text.map(AmuxChoiceParser.parse) ?? []
            guard !choices.isEmpty else {
                // No parseable menu — fall back to the free-text composer.
                self.amuxPresentPromptComposer(for: workspace)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(
                localized: "amux.choice.title",
                defaultValue: "Agent Needs a Choice"
            )
            alert.informativeText = workspace.customTitle ?? ""
            // One button per option (AppKit stacks them right-to-left, so add
            // in order and map the response back by index), then Cancel.
            for choice in choices {
                alert.addButton(withTitle: "\(choice.number). \(choice.label)")
            }
            alert.addButton(withTitle: String(localized: "amux.choice.cancel", defaultValue: "Cancel"))
            let response = alert.runModal()
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < choices.count else { return }
            let picked = choices[index]
            if !self.amuxSendPrompt("\(picked.number)", to: workspace) {
                NSSound.beep()
            }
        }
    }

    /// Remote-host setup flow: pick an SSH host with a live mirror, inspect
    /// its muxa observation stack (CLI, daemon, hooks, notifier), and offer
    /// the hooks-only `muxa init` when something is missing. Palette
    /// entrypoint; `amux.remote_setup` drives the same service headlessly.
    func amuxPresentRemoteHostSetup() {
        let hosts = remoteTmuxController.activeSSHMirrorHosts()
        guard !hosts.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
            alert.informativeText = String(
                localized: "amux.remoteSetup.noHosts",
                defaultValue: "No SSH host has a mirrored tmux session yet. Mirror a remote session first."
            )
            alert.runModal()
            return
        }
        let picker = NSAlert()
        picker.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
        for host in hosts {
            picker.addButton(withTitle: host.destination)
        }
        picker.addButton(withTitle: String(localized: "amux.remoteSetup.cancel", defaultValue: "Cancel"))
        let index = picker.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < hosts.count else { return }
        amuxPresentRemoteHostSetupReport(host: hosts[index])
    }

    /// Inspects `host` and presents the report, offering hook wiring.
    private func amuxPresentRemoteHostSetupReport(host: RemoteTmuxHost) {
        Task { @MainActor in
            let setup = AmuxRemoteHostSetup()
            do {
                let report = try await setup.inspect(host: host)
                let alert = NSAlert()
                alert.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
                alert.informativeText = Self.amuxRemoteSetupReportText(host: host, report: report)
                let fullyWired = report.muxaVersion != nil && report.muxadRunning
                    && report.claudeHooksWired && report.codexHooksWired
                if report.muxaVersion != nil, !fullyWired {
                    alert.addButton(withTitle: String(
                        localized: "amux.remoteSetup.wire",
                        defaultValue: "Wire Agent Hooks"
                    ))
                    alert.addButton(withTitle: String(localized: "amux.remoteSetup.cancel", defaultValue: "Cancel"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    _ = try await setup.wireHooks(host: host)
                    let done = NSAlert()
                    done.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
                    done.informativeText = Self.amuxRemoteSetupReportText(
                        host: host,
                        report: try await setup.inspect(host: host)
                    )
                    done.runModal()
                } else {
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
                alert.informativeText = String(
                    localized: "amux.remoteSetup.failed",
                    defaultValue: "Could not inspect the host over SSH."
                ) + "\n\(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    /// The report body: localized labels, ✓/✗ status symbols, and the
    /// cargo-install hint when the muxa CLI is missing remotely.
    static func amuxRemoteSetupReportText(host: RemoteTmuxHost, report: AmuxRemoteHostSetup.Report) -> String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        var lines = [
            host.destination,
            "",
            String(
                format: String(localized: "amux.remoteSetup.report", defaultValue: """
                muxa CLI: %@
                muxad: %@
                Claude Code hooks: %@
                Codex hooks: %@
                """),
                report.muxaVersion ?? "✗",
                mark(report.muxadRunning),
                mark(report.claudeHooksWired),
                mark(report.codexHooksWired)
            ),
        ]
        if report.muxaVersion == nil {
            lines.append(String(
                localized: "amux.remoteSetup.muxaMissing",
                defaultValue: "Install muxa on the host first: cargo install --git https://github.com/Open330/muxa muxad muxa-cli"
            ))
        }
        if report.notifierEnabled {
            lines.append(String(
                localized: "amux.remoteSetup.notifierOn",
                defaultValue: "muxa's own desktop notifier is enabled on the host — amux already alerts on this Mac, so consider disabling it there ([notifier] enabled = false)."
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Modal detail view of `workspace`'s tracked agents: kind, state,
    /// model/context, and the last prompt/response text (goal: see what an
    /// agent asked and answered without attaching). Palette entrypoint;
    /// `debug.amux.agent_details` reads the same hub accessor headlessly.
    func amuxPresentAgentDetails(for workspace: Workspace) {
        let agents = amuxAgentObservation.agents(inWorkspace: workspace.id)
        let alert = NSAlert()
        alert.messageText = String(localized: "amux.details.title", defaultValue: "Agent Details")
        alert.informativeText = agents.isEmpty
            ? String(localized: "amux.details.none", defaultValue: "No tracked agent in this workspace.")
            : agents.map(Self.amuxAgentDetailText).joined(separator: "\n\n")
        alert.runModal()
    }

    /// One agent's detail block (state/model/pane are technical wire values;
    /// the prompt/response labels are localized).
    static func amuxAgentDetailText(_ agent: MuxaAgent) -> String {
        var lines: [String] = []
        var headline = "\(AmuxAgentAlarmPolicy.displayName(for: agent.kind)) — \(agent.state.rawValue)"
        if let model = agent.model { headline += " · \(model)" }
        if let pct = agent.contextUsedPct { headline += " · \(Int(pct))%" }
        lines.append(headline)
        if let prompt = agent.lastPrompt, !prompt.isEmpty {
            lines.append(String(
                format: String(localized: "amux.details.prompt", defaultValue: "Prompt: %@"),
                Self.amuxDetailSnippet(prompt)
            ))
        }
        if let response = agent.lastResponse, !response.isEmpty {
            lines.append(String(
                format: String(localized: "amux.details.response", defaultValue: "Response: %@"),
                Self.amuxDetailSnippet(response)
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Truncates detail text to an alert-friendly single snippet.
    static func amuxDetailSnippet(_ text: String, limit: Int = 280) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
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
        guard let target = amuxAgentObservation.attendTarget() else { return false }
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
