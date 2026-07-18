import AppKit
import CmuxMuxa

private struct AmuxRemoteTmuxSyncRecord: Codable, Equatable {
    var destination: String
    var port: Int?
    var identityFile: String?
    var enabled: Bool

    var host: RemoteTmuxHost {
        RemoteTmuxHost(destination: destination, port: port, identityFile: identityFile)
    }

    init(host: RemoteTmuxHost, enabled: Bool) {
        self.destination = host.destination
        self.port = host.port
        self.identityFile = host.identityFile
        self.enabled = enabled
    }
}

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
        let finishedDebounce = AmuxAgentFinishedAlarmDebounce()
        let onTransition: @MainActor (MuxaTransition, Workspace?) -> Void = { [weak self] transition, workspace in
            // The gate sees every pass (joined or not) so episode memory
            // stays fresh, but only a joined attention pass consumes the
            // episode — an unjoined one must alarm on a later joinable pass.
            let alarm = alarmGate.alarm(for: transition, joined: workspace != nil)
            // The debounce sees every transition too (its cancellation side):
            // a "finished" alarm only survives if the agent stays idle through
            // the quiet window — milestone idle-flashes are swallowed.
            finishedDebounce.route(
                transition: transition,
                alarm: (workspace != nil) ? alarm : nil
            ) { [weak self] in
                guard let self, let alarm, let workspace else { return }
                self.amuxDeliverAgentAlarm(alarm, workspace: workspace)
            }
        }
        let localService = AmuxAgentStatusService(
            workspaceForSession: { [weak self] sessionName in
                self?.remoteTmuxController.localMirrorWorkspace(sessionName: sessionName)
            },
            workspaceForPane: { [weak self] paneId in
                self?.remoteTmuxController.localMirrorWorkspace(containingPane: paneId)
            },
            onTransition: onTransition,
            // Forget gate episode memory for sessions that vanished from this
            // daemon's snapshot (a killed agent's key can't linger). The gate
            // is shared with the remote observers, so we pass only the vanished
            // delta — never "everything except my live set", which would evict
            // their live episodes and re-alarm them.
            onSessionsVanished: { alarmGate.forget(sessionIds: $0) }
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
                    onTransition: onTransition,
                    onSessionsVanished: { alarmGate.forget(sessionIds: $0) }
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
    /// the user's sessions back without a manual attach.
    ///
    /// If the user opted into tmux sync, this also re-mirrors the user's
    /// default localhost tmux server and any SSH hosts with per-host sync
    /// enabled. Missing servers, empty session lists, and unreachable SSH hosts
    /// are silent no-ops at launch.
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
            if self.amuxLocalTmuxSessionSyncEnabled, let manager = self.tabManager {
                do {
                    _ = try await self.remoteTmuxController.mirrorLocalDefaultTmuxSessions(into: manager)
                } catch {
                    #if DEBUG
                    cmuxDebugLog("amux: local default tmux sync failed: \(error)")
                    #endif
                }
            }
            for host in self.amuxRemoteTmuxSyncHosts() {
                do {
                    _ = try await self.remoteTmuxController.mirrorHostInNewWindow(
                        host: host,
                        activateWindow: false
                    )
                } catch {
                    #if DEBUG
                    cmuxDebugLog("amux: remote tmux sync failed for \(host.destination): \(error)")
                    #endif
                }
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
            let muxadPath = RemoteTmuxHost.bundledMuxadPath()
            // launchctl bootout+bootstrap blocks on waitUntilExit; run it off
            // the main actor so this palette command can't freeze the UI
            // (parity with the onboarding install path).
            let result = await Task.detached {
                AmuxMuxadLaunchAgent().install(
                    muxadPath: muxadPath,
                    daemonAlreadyRunning: running
                )
            }.value
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
        Task { @MainActor in
            // uninstall() runs launchctl bootout (blocking waitUntilExit) off
            // the main actor so the palette command can't freeze the UI.
            await Task.detached { AmuxMuxadLaunchAgent().uninstall() }.value
            let alert = NSAlert()
            alert.messageText = String(localized: "amux.daemon.title", defaultValue: "amux Background Daemon")
            alert.informativeText = String(
                localized: "amux.daemon.uninstalled",
                defaultValue: "Removed amux's background daemon. A muxad you started yourself is left running."
            )
            alert.runModal()
        }
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

    /// Whether amux mirrors the user's default localhost tmux sessions into
    /// workspaces. This is separate from ``amuxNewWorkspaceUsesTmux``: that
    /// setting creates app-owned `-L amux` sessions, while this syncs sessions
    /// the user already runs in ordinary tmux.
    static let localTmuxSyncEnabledDefaultsKey = "amux.localTmux.syncEnabled"
    var amuxLocalTmuxSessionSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.localTmuxSyncEnabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.localTmuxSyncEnabledDefaultsKey) }
    }

    static let remoteTmuxSyncRecordsDefaultsKey = "amux.remoteTmux.syncRecords.v1"

    private var amuxRemoteTmuxSyncRecords: [String: AmuxRemoteTmuxSyncRecord] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.remoteTmuxSyncRecordsDefaultsKey),
                  let records = try? JSONDecoder().decode([String: AmuxRemoteTmuxSyncRecord].self, from: data)
            else { return [:] }
            return records
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.remoteTmuxSyncRecordsDefaultsKey)
        }
    }

    func amuxRemoteTmuxSyncEnabled(for host: RemoteTmuxHost) -> Bool {
        amuxRemoteTmuxSyncRecords[host.connectionHash]?.enabled ?? false
    }

    func amuxSetRemoteTmuxSyncEnabled(_ enabled: Bool, for host: RemoteTmuxHost) {
        guard host.kind == .ssh else { return }
        var records = amuxRemoteTmuxSyncRecords
        records[host.connectionHash] = AmuxRemoteTmuxSyncRecord(host: host, enabled: enabled)
        amuxRemoteTmuxSyncRecords = records
    }

    func amuxRemoteTmuxSyncHosts() -> [RemoteTmuxHost] {
        amuxRemoteTmuxSyncRecords.values
            .filter(\.enabled)
            .map(\.host)
            .sorted { $0.destination.localizedCaseInsensitiveCompare($1.destination) == .orderedAscending }
    }

    /// Every tmux endpoint included in the unified session switcher. Open SSH
    /// mirrors remain discoverable even when automatic sync is disabled.
    func amuxSessionSwitcherHosts() -> [RemoteTmuxHost] {
        Self.amuxSessionSwitcherHosts(
            remoteSyncHosts: amuxRemoteTmuxSyncHosts(),
            activeSSHHosts: remoteTmuxController.activeSSHMirrorHosts()
        )
    }

    static func amuxSessionSwitcherHosts(
        remoteSyncHosts: [RemoteTmuxHost],
        activeSSHHosts: [RemoteTmuxHost]
    ) -> [RemoteTmuxHost] {
        var seen: Set<String> = []
        var hosts: [RemoteTmuxHost] = []
        let remoteHosts = (remoteSyncHosts + activeSSHHosts).sorted {
            let destinationOrder = $0.destination.localizedCaseInsensitiveCompare($1.destination)
            if destinationOrder != .orderedSame { return destinationOrder == .orderedAscending }
            return $0.id < $1.id
        }
        for host in [RemoteTmuxHost.amuxLocal(), .localDefault()] + remoteHosts
        where seen.insert(host.id).inserted {
            hosts.append(host)
        }
        return hosts
    }

    /// Builds the host-level loader injected into each window's switcher coordinator.
    func makeAmuxSessionSwitcherLoader() -> AmuxSessionSwitcherLoader {
        AmuxSessionSwitcherLoader(
            remoteTmuxController: remoteTmuxController,
            agentObservation: amuxAgentObservation
        )
    }

    /// Toggles sync for the user's default localhost tmux server. Turning sync
    /// off stops future automatic mirrors; it deliberately leaves currently open
    /// mirror workspaces alone so no tmux client/session is detached out from
    /// under the user.
    func amuxToggleLocalTmuxSessionSync() {
        amuxLocalTmuxSessionSyncEnabled.toggle()
        if amuxLocalTmuxSessionSyncEnabled {
            amuxMirrorLocalDefaultTmuxSessions(presentResult: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "amux.localSync.disabled.title",
            defaultValue: "Local tmux Sync Off"
        )
        alert.informativeText = String(
            localized: "amux.localSync.disabled.body",
            defaultValue: "amux will stop auto-syncing localhost tmux sessions. Open mirror workspaces stay open until you close them."
        )
        AmuxOnboarding.present(alert) { _ in }
    }

    /// Mirrors the user's default localhost tmux sessions into the key window's
    /// workspace list. Existing mirrors are de-duplicated by tmux session id/name.
    func amuxMirrorLocalDefaultTmuxSessions(presentResult: Bool = false) {
        guard let manager = tabManager else { NSSound.beep(); return }
        Task { @MainActor in
            do {
                let result = try await self.remoteTmuxController.mirrorLocalDefaultTmuxSessions(into: manager)
                guard presentResult else { return }
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "amux.localSync.enabled.title",
                    defaultValue: "Local tmux Sync On"
                )
                if result.discovered == 0 {
                    alert.informativeText = String(
                        localized: "amux.localSync.noSessions",
                        defaultValue: "Sync is on, but the localhost tmux server has no sessions yet."
                    )
                } else {
                    alert.informativeText = String(
                        format: String(
                            localized: "amux.localSync.synced.body",
                            defaultValue: "Found %lld localhost tmux session(s); %lld new workspace(s) were mirrored. tmux windows appear as amux tabs, and tmux panes stay split inside each tab."
                        ),
                        Int64(result.discovered),
                        Int64(result.mirrored)
                    )
                }
                AmuxOnboarding.present(alert) { _ in }
            } catch {
                NSSound.beep()
                guard presentResult else { return }
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "amux.localSync.failed.title",
                    defaultValue: "Local tmux Sync Failed"
                )
                alert.informativeText = error.localizedDescription
                AmuxOnboarding.present(alert) { _ in }
            }
        }
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

    /// Mirrors the detached amux session `name` into `manager` and selects
    /// it. Returns `false` when the mirror could not be created.
    @discardableResult
    func amuxAttachSession(
        named name: String,
        in manager: TabManager,
        focusWorkspace: Bool = true
    ) -> Bool {
        amuxAttachSession(
            host: .amuxLocal(),
            sessionName: name,
            sessionId: nil,
            in: manager,
            focusWorkspace: focusWorkspace
        )
    }

    private func amuxAttachSession(
        host: RemoteTmuxHost,
        sessionName: String,
        sessionId: Int?,
        in manager: TabManager,
        focusWorkspace: Bool
    ) -> Bool {
        do {
            guard let targetManager = remoteTmuxController.sessionAttachTargetTabManager(
                host: host,
                fallback: manager
            ) else { return false }
            try remoteTmuxController.mirrorSession(
                host: host,
                sessionName: sessionName,
                sessionId: sessionId,
                into: targetManager
            )
            let workspace = sessionId.flatMap {
                remoteTmuxController.mirrorWorkspace(hostId: host.id, sessionId: $0)
            } ?? remoteTmuxController.mirrorWorkspace(hostId: host.id, sessionName: sessionName)
            if let workspace {
                let owner = amuxWorkspace(withId: workspace.id)?.manager ?? targetManager
                Self.focusWorkspaceAfterSessionAttach(
                    ifRequested: focusWorkspace,
                    workspace: workspace,
                    owner: owner,
                    bringForward: { $0.window?.makeKeyAndOrderFront(nil) }
                )
            }
            return true
        } catch {
            #if DEBUG
            cmuxDebugLog("amux: attach session \(sessionName) on \(host.destination) failed: \(error)")
            #endif
            return false
        }
    }

    /// Mirrors a discovered detached session into `manager`, preserving tmux's
    /// stable numeric session id for de-duplication, and selects the workspace.
    @discardableResult
    func amuxAttachSession(
        host: RemoteTmuxHost,
        session: RemoteTmuxSession,
        in manager: TabManager,
        focusWorkspace: Bool = true
    ) -> Bool {
        amuxAttachSession(
            host: host,
            sessionName: session.name,
            sessionId: RemoteTmuxController.tmuxSessionNumericId(session.id),
            in: manager,
            focusWorkspace: focusWorkspace
        )
    }

    static func focusWorkspaceAfterSessionAttach(
        ifRequested focusWorkspace: Bool,
        workspace: Workspace,
        owner: TabManager,
        bringForward: (TabManager) -> Void
    ) {
        guard focusWorkspace else { return }
        owner.selectWorkspace(workspace)
        bringForward(owner)
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

    private func amuxRemoteHostCandidates() -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []
        func append(_ destination: String) {
            guard !destination.isEmpty, seen.insert(destination).inserted else { return }
            candidates.append(destination)
        }
        for host in remoteTmuxController.activeSSHMirrorHosts() {
            append(host.destination)
        }
        for record in amuxRemoteTmuxSyncRecords.values {
            append(record.destination)
        }
        for alias in Self.amuxSSHConfigHostAliases() {
            append(alias)
        }
        return candidates
    }

    nonisolated static func amuxSSHConfigHostAliases(configPath: String? = nil) -> [String] {
        let path = configPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config").path
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var aliases: [String] = []
        var seen = Set<String>()
        for line in contents.split(whereSeparator: \.isNewline) {
            let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = noComment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.first?.lowercased() == "host" else { continue }
            for alias in parts.dropFirst() {
                guard !alias.isEmpty,
                      !alias.contains("*"),
                      !alias.contains("?"),
                      !alias.contains("!"),
                      !alias.contains("%"),
                      seen.insert(alias).inserted
                else { continue }
                aliases.append(alias)
            }
        }
        return aliases.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Remote-host setup flow: pick an SSH host, inspect its muxa observation
    /// stack (CLI, daemon, hooks, notifier), detect tmux sessions, and offer
    /// per-host tmux sync. Palette entrypoint; `amux.remote_setup` drives the
    /// same service headlessly.
    func amuxPresentRemoteHostSetup() {
        let candidates = amuxRemoteHostCandidates()
        let picker = NSAlert()
        picker.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
        picker.informativeText = String(
            localized: "amux.remoteSetup.pickHost",
            defaultValue: "Choose an SSH config alias or enter a host to inspect. If tmux sessions exist, you can turn sync on for this host."
        )
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        combo.completes = true
        combo.usesDataSource = false
        combo.addItems(withObjectValues: candidates)
        combo.stringValue = candidates.first ?? ""
        picker.accessoryView = combo
        picker.addButton(withTitle: String(localized: "amux.remoteSetup.continue", defaultValue: "Continue"))
        picker.addButton(withTitle: String(localized: "amux.remoteSetup.cancel", defaultValue: "Cancel"))
        guard picker.runModal() == .alertFirstButtonReturn else { return }
        let destination = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = TerminalController.remoteTmuxHost(from: ["host": destination]), host.kind == .ssh else {
            let alert = NSAlert()
            alert.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
            alert.informativeText = String(
                localized: "amux.remoteSetup.invalidHost",
                defaultValue: "Enter a valid SSH host or ~/.ssh/config alias."
            )
            alert.runModal()
            return
        }
        amuxPresentRemoteHostSetupReport(host: host)
    }

    /// Inspects `host` and presents the report, offering hook wiring.
    private func amuxPresentRemoteHostSetupReport(host: RemoteTmuxHost) {
        Task { @MainActor in
            let setup = AmuxRemoteHostSetup()
            do {
                let report = try await setup.inspect(host: host)
                let tmuxSessions = try? await self.remoteTmuxController.listSessions(host: host)
                let tmuxSyncEnabled = self.amuxRemoteTmuxSyncEnabled(for: host)
                let alert = NSAlert()
                alert.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
                alert.informativeText = Self.amuxRemoteSetupReportText(
                    host: host,
                    report: report,
                    tmuxSessions: tmuxSessions,
                    tmuxSyncEnabled: tmuxSyncEnabled
                )
                let fullyWired = report.muxaVersion != nil && report.muxadRunning
                    && report.claudeHooksWired && report.codexHooksWired
                enum Action {
                    case sync
                    case disableSync
                    case wire
                    case done
                }
                var actions: [(title: String, action: Action)] = []
                if tmuxSessions?.isEmpty == false {
                    actions.append((
                        String(
                            localized: "amux.remoteSetup.syncNow",
                            defaultValue: "Sync tmux Sessions"
                        ),
                        .sync
                    ))
                    if tmuxSyncEnabled {
                        actions.append((
                            String(
                                localized: "amux.remoteSetup.disableSync",
                                defaultValue: "Turn Off Sync"
                            ),
                            .disableSync
                        ))
                    }
                }
                if report.muxaVersion != nil, !fullyWired {
                    actions.append((
                        String(
                            localized: "amux.remoteSetup.wire",
                            defaultValue: "Wire Agent Hooks"
                        ),
                        .wire
                    ))
                }
                actions.append((
                    String(localized: "amux.remoteSetup.done", defaultValue: "Done"),
                    .done
                ))
                for action in actions {
                    alert.addButton(withTitle: action.title)
                }
                let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard index >= 0, index < actions.count else { return }
                switch actions[index].action {
                case .sync:
                    let outcome = try await self.remoteTmuxController.mirrorHostInNewWindow(host: host, activateWindow: true)
                    switch outcome {
                    case .mirrored:
                        self.amuxSetRemoteTmuxSyncEnabled(true, for: host)
                    case .authRequired(let sshArgv):
                        let auth = NSAlert()
                        auth.messageText = String(
                            localized: "amux.remoteSetup.authRequired.title",
                            defaultValue: "SSH Authentication Required"
                        )
                        auth.informativeText = String(
                            format: String(
                                localized: "amux.remoteSetup.authRequired.body",
                                defaultValue: "Run this in a terminal to authenticate, then return to Remote Host Setup and sync again:\n\n%@"
                            ),
                            sshArgv.joined(separator: " ")
                        )
                        auth.runModal()
                    }
                case .disableSync:
                    self.amuxSetRemoteTmuxSyncEnabled(false, for: host)
                    let done = NSAlert()
                    done.messageText = String(localized: "amux.remoteSetup.title", defaultValue: "Remote Host Setup")
                    done.informativeText = String(
                        localized: "amux.remoteSetup.syncDisabled",
                        defaultValue: "Sync is off for this host. Existing mirror workspaces stay open until you close them."
                    )
                    done.runModal()
                case .wire:
                    _ = try await setup.wireHooks(host: host)
                    self.amuxPresentRemoteHostSetupReport(host: host)
                case .done:
                    break
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
    static func amuxRemoteSetupReportText(
        host: RemoteTmuxHost,
        report: AmuxRemoteHostSetup.Report,
        tmuxSessions: [RemoteTmuxSession]? = nil,
        tmuxSyncEnabled: Bool = false
    ) -> String {
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
        let tmuxLine: String
        if let tmuxSessions {
            if tmuxSessions.isEmpty {
                tmuxLine = String(
                    localized: "amux.remoteSetup.tmuxNone",
                    defaultValue: "tmux sessions: none"
                )
            } else {
                tmuxLine = String(
                    format: String(
                        localized: "amux.remoteSetup.tmuxFound",
                        defaultValue: "tmux sessions: %lld (windows open as amux tabs; panes stay split inside each tab)"
                    ),
                    Int64(tmuxSessions.count)
                )
            }
        } else {
            tmuxLine = String(
                localized: "amux.remoteSetup.tmuxUnknown",
                defaultValue: "tmux sessions: could not inspect"
            )
        }
        lines.append(tmuxLine)
        lines.append(tmuxSyncEnabled
            ? String(localized: "amux.remoteSetup.syncOn", defaultValue: "tmux sync: on for this host")
            : String(localized: "amux.remoteSetup.syncOff", defaultValue: "tmux sync: off for this host"))
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
        if let cost = agent.costUsd { headline += " · \(cost.formatted(.currency(code: "USD")))" }
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
