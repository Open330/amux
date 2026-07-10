import Foundation

/// Socket/CLI handlers for the remote-tmux (`ssh … tmux -CC`) beta feature.
///
/// These run on the socket worker (registered in `socketWorkerV2Methods`) so
/// the SSH round-trips never block the main actor. Each handler gates on the
/// `remoteTmux` beta flag and delegates to `AppDelegate`'s
/// ``RemoteTmuxController``.
extension TerminalController {
    /// `remote.tmux.sessions` — list the tmux sessions on a host.
    ///
    /// Params: `host` (required SSH destination/alias), optional `port` (Int),
    /// optional `identity_file` (String).
    nonisolated func v2RemoteTmuxSessions(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let sessions = try await controller.listSessions(host: host)
            return [
                "host": host.destination,
                "sessions": sessions.map { Self.sessionPayload($0) },
            ]
        }
    }

    /// Builds a ``RemoteTmuxHost`` from socket params (`host`, `port`, `identity_file`).
    ///
    /// Rejects a destination (or identity file) beginning with `-`: even with the
    /// `--` end-of-options guard in the argv builders, a dash-prefixed
    /// destination is never a legitimate SSH alias/`user@host`, and refusing it
    /// at the trust boundary is defense in depth against ssh option injection
    /// (`-oProxyCommand=…` → local command execution).
    nonisolated static func remoteTmuxHost(from params: [String: Any]) -> RemoteTmuxHost? {
        // `local_default: true` addresses the user's default localhost tmux
        // server. `local: true` addresses the amux local engine — a fixed
        // endpoint with no SSH fields, so none of the destination validation
        // below applies (and a caller-supplied `host` string could never resolve
        // to either local endpoint: the local kind is part of the connection hash).
        if params["local_default"] as? Bool == true {
            return .localDefault()
        }
        if params["local"] as? Bool == true {
            return .amuxLocal()
        }
        guard let destination = (params["host"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty,
            !destination.hasPrefix("-"),
            !Self.remoteTmuxValueHasHiddenCharacter(destination)
        else { return nil }
        let port = params["port"] as? Int
        // Reject an out-of-range port at the trust boundary (consistent with the
        // dash-prefix/hidden-char rejections above) instead of silently falling back
        // to the SSH default.
        if let port, !(1...65535).contains(port) { return nil }
        let identityFile = (params["identity_file"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let identityFile, identityFile.hasPrefix("-") { return nil }
        if let identityFile, Self.remoteTmuxValueHasHiddenCharacter(identityFile) { return nil }
        return RemoteTmuxHost(
            destination: destination,
            port: port,
            identityFile: (identityFile?.isEmpty == false) ? identityFile : nil
        )
    }

    /// Rejects control / format / separator scalars in an SSH destination or
    /// identity-file path. These hidden characters never appear in a legitimate
    /// `user@host` / alias / key path, and refusing them at the socket boundary
    /// blocks attempts to smuggle terminal escapes or obscure the real target —
    /// defense in depth alongside the dash-prefix rejection and the argv `--`
    /// end-of-options guard.
    nonisolated static func remoteTmuxValueHasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    /// `remote.tmux.attach` — attach a `tmux -CC` control client to a session.
    ///
    /// Params: `host` (required), `session` (required tmux session name),
    /// optional `create` (Bool — attach-or-create). Returns the control surface id.
    nonisolated func v2RemoteTmuxAttach(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        guard let session = Self.remoteTmuxSessionName(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.sessionRequired", defaultValue: "session is required"))
        }
        let createIfMissing = (params["create"] as? Bool) ?? false
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            if let sshArgv = try await controller.attachControlStreamWhenReady(
                host: host,
                sessionName: session,
                createIfMissing: createIfMissing
            ) {
                return [
                    "host": host.destination,
                    "session": session,
                    "auth_required": true,
                    "ssh_argv": sshArgv,
                ]
            }
            return [
                "host": host.destination,
                "session": session,
                "attached": true,
            ]
        }
    }

    /// `remote.tmux.mirror` — mirror every tmux session on a host as its own
    /// sidebar workspace (windows become tabs). Params: `host` (required).
    /// Mirrors into the host's dedicated mirror window when one is bound
    /// (#7363); otherwise into the key window's sidebar.
    nonisolated func v2RemoteTmuxMirror(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            try await controller.mirrorHost(host: host)
            return ["host": host.destination, "mirrored": true]
        }
    }

    /// `remote.tmux.window` — open a dedicated cmux window mirroring every tmux
    /// session on a host (the `cmux ssh-tmux` CLI entry point).
    ///
    /// Params: `host` (required), optional `port` (Int), optional `identity_file`
    /// (String), optional `activate` (Bool, default `true`).
    ///
    /// Returns `{mirrored: true, window_id}` on success, or
    /// `{auth_required: true, ssh_argv: […]}` when the host needs interactive
    /// authentication. cmux's control client uses plain pipes and cannot prompt,
    /// so the CLI runs `ssh_argv` in the user's terminal (where the tty makes
    /// password / host-key / MFA / FIDO prompts work) to open the shared
    /// ControlMaster, then re-issues this command — which now succeeds by
    /// multiplexing over the authenticated master.
    nonisolated func v2RemoteTmuxWindow(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let activate = (params["activate"] as? Bool) ?? true
        // 60s (the CLI waits longer still) so a slow-but-valid BatchMode probe
        // completes instead of the app timing out first and turning an
        // auth-required result into an opaque timeout error.
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let outcome = try await controller.mirrorHostInNewWindow(host: host, activateWindow: activate)
            switch outcome {
            case .mirrored(let windowId):
                return [
                    "host": host.destination,
                    "mirrored": true,
                    "window_id": windowId.uuidString,
                ]
            case .authRequired(let sshArgv):
                return [
                    "host": host.destination,
                    "auth_required": true,
                    "ssh_argv": sshArgv,
                ]
            }
        }
    }

    /// `remote.tmux.detach` — detach a control client and remove its mirror workspace;
    /// leaves the remote session alive.
    nonisolated func v2RemoteTmuxDetach(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostAndSessionRequired", defaultValue: "host and session are required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            try await MainActor.run {
                guard let controller = AppDelegate.shared?.remoteTmuxController else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                controller.detach(host: host, sessionName: session)
            }
            return ["host": host.destination, "session": session, "detached": true]
        }
    }

    /// `remote.tmux.state` — report a control client's observed control-mode state.
    ///
    /// Diagnostics surface for verifying the ghostty → cmux event pipe end to end.
    nonisolated func v2RemoteTmuxState(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostAndSessionRequired", defaultValue: "host and session are required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            let snapshot: RemoteTmuxControlConnection.Snapshot? = await MainActor.run {
                AppDelegate.shared?.remoteTmuxController
                    .connection(host: host, sessionName: session)?
                    .snapshot()
            }
            guard let snapshot else {
                return ["host": host.destination, "session": session, "attached": false]
            }
            var paneBytes: [String: Int] = [:]
            for (paneId, count) in snapshot.paneOutputByteCounts {
                paneBytes["%\(paneId)"] = count
            }
            var payload: [String: Any] = [
                "host": host.destination,
                "session": session,
                "attached": true,
                "started": snapshot.started,
                "enter_received": snapshot.enterReceived,
                "exited": snapshot.exited,
                "window_count": snapshot.windowCount,
                "window_ids": snapshot.windowIDs,
                "total_output_bytes": snapshot.totalOutputBytes,
                "pane_output_bytes": paneBytes,
                "recent_events": snapshot.recentEvents,
            ]
            if let sessionId = snapshot.sessionId {
                payload["session_id"] = sessionId
            }
            return payload
        }
    }

    /// Extracts a required tmux session name from socket params.
    nonisolated static func remoteTmuxSessionName(from params: [String: Any]) -> String? {
        guard let session = (params["session"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !session.isEmpty
        else { return nil }
        return session
    }

    /// Serializes a session for the socket response.
    /// Socket I/O target for `panel` in `workspace`: mirrored multipane
    /// window-tabs redirect to the active pane's panel (the tab's own surface
    /// is disconnected from tmux and would silently swallow input); every
    /// other panel passes through unchanged.
    @MainActor
    func remoteTmuxSocketPanel(_ panel: TerminalPanel, panelId: UUID, in workspace: Workspace) -> TerminalPanel {
        let redirected = AppDelegate.shared?.remoteTmuxController
            .socketTargetPanel(workspaceId: workspace.id, panelId: panelId)
        #if DEBUG
        cmuxDebugLog("amux.socketRedirect panel=\(panelId) -> \(redirected.map { String(describing: $0.id) } ?? "nil (passthrough)")")
        #endif
        return redirected ?? panel
    }

    nonisolated static func sessionPayload(_ session: RemoteTmuxSession) -> [String: Any] {
        var dict: [String: Any] = [
            "id": session.id,
            "name": session.name,
            "windows": session.windowCount,
            "attached": session.attached,
        ]
        if let created = session.createdUnix {
            dict["created"] = created
        }
        return dict
    }

    /// `amux.send_prompt` — headless prompt into a mirror workspace's agent
    /// pane. Params: `text` (required), `workspace_id` (optional UUID/ref;
    /// defaults to the key window's selected workspace). NOT focus-intent:
    /// the send is data-only and must never steal focus.
    nonisolated func v2AmuxSendPrompt(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.amux.textRequired", defaultValue: "text is required"),
                data: nil
            )
        }
        return v2MainSync {
            guard let appDelegate = AppDelegate.shared else {
                return .err(
                    code: "unavailable",
                    message: String(localized: "socket.amux.appNotReady", defaultValue: "App is not ready"),
                    data: nil
                )
            }
            guard let workspaceId = self.v2AmuxResolveWorkspaceId(params),
                  let workspace = appDelegate.amuxWorkspace(withId: workspaceId)?.workspace else {
                return .err(
                    code: "not_found",
                    message: String(localized: "socket.amux.workspaceNotFound", defaultValue: "Workspace not found"),
                    data: nil
                )
            }
            guard appDelegate.amuxSendPrompt(text, to: workspace) else {
                return .err(
                    code: "not_mirror",
                    message: String(
                        localized: "socket.amux.notMirror",
                        defaultValue: "Workspace is not a live tmux mirror"
                    ),
                    data: nil
                )
            }
            return .ok(["sent": true, "workspace_id": workspace.id.uuidString])
        }
    }

    /// Accepts a tmux pane param as an Int (`3`) or a sigil string (`"%3"`).
    nonisolated static func v2TmuxPaneParam(_ raw: Any?) -> Int? {
        if let number = raw as? Int { return number }
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return Int(trimmed.hasPrefix("%") ? String(trimmed.dropFirst()) : trimmed)
    }

    /// Resolves the amux workspace a pane-driving RPC targets: `workspace_id`
    /// when given (must exist), else the key window's selected workspace.
    /// Main-actor; returns the id so worker-lane callers don't carry the
    /// non-Sendable `Workspace` across the hop.
    @MainActor
    func v2AmuxResolveWorkspaceId(_ params: [String: Any]) -> UUID? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        v2RefreshKnownRefs()
        if params.keys.contains("workspace_id") {
            guard let workspaceId = v2UUID(params, "workspace_id") else { return nil }
            return appDelegate.amuxWorkspace(withId: workspaceId)?.workspace.id
        }
        return appDelegate.tabManager?.selectedTab?.id
    }

    /// `amux.pane_read` — agent-driving read of a mirrored pane's screen (plus
    /// optional scrollback tail). Params: `workspace_id?`, `pane?` (`%N` or N),
    /// `history_lines?` (0–5000, default 0 = visible screen only). Returns
    /// `{workspace_id, pane, lines, history_size}`; `history_size` acts as an
    /// incremental cursor (`history_size - lastSeen` bounds the new scrollback
    /// since the caller's previous read). Worker lane (one-shot tmux round
    /// trips). The read primitive of the agent-driving trio
    /// (`pane_read` / `pane_wait` / `pane_send`).
    nonisolated func v2AmuxPaneRead(id: Any?, params: [String: Any]) -> String {
        let historyLines = min(max((params["history_lines"] as? Int) ?? 0, 0), 5000)
        let paneParam = Self.v2TmuxPaneParam(params["pane"])
        return v2VmCall(id: id, timeoutSeconds: 20) {
            let resolved = await MainActor.run { () -> (UUID, RemoteTmuxController)? in
                guard let appDelegate = AppDelegate.shared,
                      let workspaceId = self.v2AmuxResolveWorkspaceId(params) else { return nil }
                return (workspaceId, appDelegate.remoteTmuxController)
            }
            guard let (workspaceId, controller) = resolved else {
                throw RemoteTmuxError.unreachable("workspace not found")
            }
            guard let read = await controller.readMirrorPane(
                workspaceId: workspaceId, tmuxPane: paneParam, historyLines: historyLines
            ) else {
                throw RemoteTmuxError.unreachable("workspace has no live mirrored pane")
            }
            var lines = read.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            return [
                "workspace_id": workspaceId.uuidString,
                "pane": read.pane,
                "lines": lines,
                "history_size": read.historySize,
            ]
        }
    }

    /// `amux.pane_wait` — blocks until a mirrored pane settles. Params:
    /// `workspace_id?`, `pane?`, `for` = `"idle"` (default) | `"exit"`,
    /// `timeout_ms` (1s–10min, default 60s), `quiet_ms` (default 1500).
    ///
    /// `idle` resolves when the pane stopped streaming output for `quiet_ms`
    /// AND muxa (when it tracks an agent there) does not report
    /// working/starting — the "agent finished its turn, safe to read/send"
    /// barrier an orchestrating agent needs between `pane_send` and
    /// `pane_read`. `exit` resolves when the pane closed or its foreground
    /// fell back to a plain shell. Timing out is an `{result: "timeout"}`
    /// success, not an error. Worker lane (long poll).
    nonisolated func v2AmuxPaneWait(id: Any?, params: [String: Any]) -> String {
        let waitFor = ((params["for"] as? String) ?? "idle").lowercased()
        guard waitFor == "idle" || waitFor == "exit" else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.amux.waitForInvalid",
                    defaultValue: "for must be \"idle\" or \"exit\""
                )
            )
        }
        let timeoutMs = min(max((params["timeout_ms"] as? Int) ?? 60_000, 1_000), 600_000)
        let quietMs = min(max((params["quiet_ms"] as? Int) ?? 1_500, 250), 30_000)
        let paneParam = Self.v2TmuxPaneParam(params["pane"])
        return v2VmCall(id: id, timeoutSeconds: Double(timeoutMs) / 1000 + 10) {
            let resolved = await MainActor.run { () -> (UUID, RemoteTmuxController, AmuxAgentObservationHub)? in
                guard let appDelegate = AppDelegate.shared,
                      let workspaceId = self.v2AmuxResolveWorkspaceId(params) else { return nil }
                return (workspaceId, appDelegate.remoteTmuxController, appDelegate.amuxAgentObservation)
            }
            guard let (workspaceId, controller, observation) = resolved else {
                throw RemoteTmuxError.unreachable("workspace not found")
            }
            let clock = ContinuousClock()
            let started = clock.now
            let deadline = started.advanced(by: .milliseconds(timeoutMs))
            var lockedPane = paneParam
            var lastBytes: Int?
            var quietSince: ContinuousClock.Instant?
            var lastForeground: String?
            var lastAgentState: String?
            func payload(_ result: String, pane: Int?, foreground: String?, agentState: String?) -> [String: Any] {
                var dict: [String: Any] = [
                    "workspace_id": workspaceId.uuidString,
                    "result": result,
                    "waited_ms": Int((clock.now - started).components.seconds * 1000)
                        + Int((clock.now - started).components.attoseconds / 1_000_000_000_000_000),
                ]
                if let pane { dict["pane"] = pane }
                if let foreground { dict["foreground"] = foreground }
                if let agentState { dict["agent_state"] = agentState }
                return dict
            }
            while clock.now < deadline {
                let requestedPane = lockedPane
                let sample = await MainActor.run {
                    () -> (RemoteTmuxController.MirrorPaneObservation?, String?) in
                    let observed = controller.observeMirrorPane(workspaceId: workspaceId, tmuxPane: requestedPane)
                    var agentState: String?
                    if let pane = observed?.pane {
                        agentState = observation.agents(inWorkspace: workspaceId)
                            .first { AmuxAgentStatusService.paneNumber($0.pane) == pane }?
                            .state.rawValue
                    }
                    return (observed, agentState)
                }
                guard let observed = sample.0 else {
                    return payload("exit", pane: lockedPane, foreground: nil, agentState: sample.1)
                }
                if lockedPane == nil { lockedPane = observed.pane }
                let foreground = observed.foreground?.command
                lastForeground = foreground
                lastAgentState = sample.1
                if !observed.paneExists {
                    return payload("exit", pane: observed.pane, foreground: foreground, agentState: sample.1)
                }
                if waitFor == "exit", let state = observed.foreground, !state.hasActiveCommand {
                    return payload("exit", pane: observed.pane, foreground: foreground, agentState: sample.1)
                }
                let now = clock.now
                if lastBytes != observed.outputBytes {
                    lastBytes = observed.outputBytes
                    quietSince = now
                } else if quietSince == nil {
                    quietSince = now
                }
                if waitFor == "idle" {
                    let muxaBusy = sample.1 == "working" || sample.1 == "starting"
                    let quietLongEnough = quietSince.map { now - $0 >= .milliseconds(quietMs) } ?? false
                    if !muxaBusy, quietLongEnough {
                        return payload("idle", pane: observed.pane, foreground: foreground, agentState: sample.1)
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            return payload(
                "timeout",
                pane: lockedPane,
                foreground: lastForeground,
                agentState: lastAgentState
            )
        }
    }

    /// `amux.pane_send` — guarded agent-directed send into a mirrored pane.
    /// Params: `text` (required), `workspace_id?`, `pane?`, `enter?` (default
    /// true), `guarded?` (default true). With the guard on, the pane's
    /// foreground must be an interactive (non-shell) app; a bare shell refuses
    /// with `not_sendable` + the foreground command, so an agent-directed
    /// prompt can never be executed as shell commands. Multi-line text rides
    /// the bracketed tmux paste path (Enter queued after the paste flush).
    /// NOT focus-intent.
    nonisolated func v2AmuxPaneSend(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String, !text.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.amux.textRequired", defaultValue: "text is required"),
                data: nil
            )
        }
        let enter = (params["enter"] as? Bool) ?? true
        let guarded = (params["guarded"] as? Bool) ?? true
        let paneParam = Self.v2TmuxPaneParam(params["pane"])
        return v2MainSync {
            guard let appDelegate = AppDelegate.shared,
                  let workspaceId = self.v2AmuxResolveWorkspaceId(params) else {
                return .err(
                    code: "not_found",
                    message: String(localized: "socket.amux.workspaceNotFound", defaultValue: "Workspace not found"),
                    data: nil
                )
            }
            switch appDelegate.remoteTmuxController.guardedSendToMirror(
                workspaceId: workspaceId, tmuxPane: paneParam, text: text, enter: enter, guarded: guarded
            ) {
            case let .sent(pane):
                return .ok([
                    "sent": true,
                    "workspace_id": workspaceId.uuidString,
                    "pane": pane,
                ])
            case .notMirror:
                return .err(
                    code: "not_mirror",
                    message: String(
                        localized: "socket.amux.notMirror",
                        defaultValue: "Workspace is not a live tmux mirror"
                    ),
                    data: nil
                )
            case let .notSendable(pane, foreground):
                var data: [String: Any] = ["pane": pane]
                if let foreground { data["foreground"] = foreground }
                return .err(
                    code: "not_sendable",
                    message: String(
                        localized: "socket.amux.paneNotSendable",
                        defaultValue: "Pane foreground is not an interactive agent (pass guarded=false to send anyway)"
                    ),
                    data: data
                )
            }
        }
    }

    /// `amux.agents` — detect catalog agent CLIs on the local amux host, or on
    /// the host backing optional `workspace_id`. Returns the host identity and
    /// `{agents: [{agent, name, installed, path?}]}`. Worker lane.
    nonisolated func v2AmuxAgents(id: Any?, params: [String: Any]) -> String {
        v2AsyncResultCall(id: id, timeoutSeconds: 30) {
            let explicitTarget = params.keys.contains("workspace_id")
            let resolved = await MainActor.run { () -> (RemoteTmuxController, UUID?)? in
                guard let app = AppDelegate.shared else { return nil }
                if explicitTarget {
                    guard let workspaceId = self.v2AmuxResolveWorkspaceId(params) else { return nil }
                    return (app.remoteTmuxController, workspaceId)
                }
                return (app.remoteTmuxController, nil)
            }
            guard let (controller, workspaceId) = resolved else {
                return .err(
                    code: "not_found",
                    message: String(localized: "socket.amux.workspaceNotFound", defaultValue: "Workspace not found"),
                    data: nil
                )
            }
            do {
                guard let detected = try await controller.detectAgentCatalogPaths(
                    workspaceId: workspaceId
                ) else {
                    return .err(
                        code: "not_mirror",
                        message: String(localized: "socket.amux.notMirror", defaultValue: "Workspace is not a live tmux mirror"),
                        data: nil
                    )
                }
                var result: [String: Any] = [
                    "host": detected.host.destination,
                    "host_kind": Self.amuxHostKind(detected.host.kind),
                    "agents": AmuxAgentCatalog.detectionRows(paths: detected.paths),
                ]
                if let workspaceId { result["workspace_id"] = workspaceId.uuidString }
                return .ok(result)
            } catch {
                return .err(code: "detection_failed", message: String(describing: error), data: nil)
            }
        }
    }

    /// `amux.launch_agent` — start a catalog agent in an amux pane. Params:
    /// `agent` (required, catalog id), `prompt?`, `workspace_id?` (default:
    /// create a NEW amux session). The launch line is typed into the pane's
    /// shell behind the inverse sendability guard (a pane running an
    /// interactive app refuses with `pane_busy`). For agents that take no
    /// startup prompt amux waits for tmux's foreground event and delivers the
    /// prompt automatically. A readiness timeout returns `followup_prompt` so
    /// a coordinator can recover with pane_wait + pane_send. Worker lane.
    nonisolated func v2AmuxLaunchAgent(id: Any?, params: [String: Any]) -> String {
        guard let agentId = (params["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let entry = AmuxAgentCatalog.entry(id: agentId) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.amux.agentUnknown",
                    defaultValue: "agent must be one of the amux agent catalog ids (see amux.agents)"
                )
            )
        }
        let rawPrompt = params["prompt"] as? String
        let prompt = rawPrompt.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let paneParam = Self.v2TmuxPaneParam(params["pane"])
        return v2AsyncResultCall(id: id, timeoutSeconds: 60) {
            var sessionName: String?
            let explicitTarget = params.keys.contains("workspace_id")
            let appContext = await MainActor.run {
                AppDelegate.shared.map { ($0.remoteTmuxController, $0.tabManager) }
            }
            guard let (controller, manager) = appContext else {
                return .err(
                    code: "not_ready",
                    message: String(localized: "socket.amux.appNotReady", defaultValue: "App is not ready"),
                    data: nil
                )
            }

            let requestedWorkspaceId: UUID?
            if explicitTarget {
                requestedWorkspaceId = await MainActor.run {
                    self.v2AmuxResolveWorkspaceId(params)
                }
                guard requestedWorkspaceId != nil else {
                    return .err(
                        code: "not_found",
                        message: String(localized: "socket.amux.workspaceNotFound", defaultValue: "Workspace not found"),
                        data: nil
                    )
                }
            } else {
                requestedWorkspaceId = nil
            }

            let detected: (paths: [String: String], host: RemoteTmuxHost)
            do {
                guard let value = try await controller.detectAgentCatalogPaths(
                    workspaceId: requestedWorkspaceId
                ) else {
                    return .err(
                        code: "not_mirror",
                        message: String(localized: "socket.amux.notMirror", defaultValue: "Workspace is not a live tmux mirror"),
                        data: nil
                    )
                }
                detected = value
            } catch {
                return .err(code: "detection_failed", message: String(describing: error), data: nil)
            }
            guard let executable = entry.resolvedExecutable(in: detected.paths) else {
                return .err(
                    code: "agent_not_installed",
                    message: String(
                        format: String(
                            localized: "socket.amux.agentNotInstalled",
                            defaultValue: "%@ is not installed on %@"
                        ),
                        entry.displayName,
                        detected.host.destination
                    ),
                    data: ["agent": entry.id, "host": detected.host.destination]
                )
            }

            let workspaceId: UUID
            if let requestedWorkspaceId {
                workspaceId = requestedWorkspaceId
            } else {
                guard let manager else {
                    return .err(
                        code: "not_ready",
                        message: String(localized: "socket.amux.appNotReady", defaultValue: "App is not ready"),
                        data: nil
                    )
                }
                do {
                    let name = try await controller.createLocalAmuxWorkspace(into: manager)
                    sessionName = name
                    guard let createdId = await MainActor.run(body: {
                        controller.localMirrorWorkspace(sessionName: name)?.id
                    }) else {
                        return .err(
                            code: "not_mirror",
                            message: String(localized: "socket.amux.notMirror", defaultValue: "Workspace is not a live tmux mirror"),
                            data: nil
                        )
                    }
                    workspaceId = createdId
                } catch {
                    return .err(code: "launch_failed", message: String(describing: error), data: nil)
                }
            }

            let launchLine = entry.launchLine(prompt: prompt, executable: executable)
            // A just-created mirror needs a beat before its pane resolves;
            // retry briefly on .notMirror instead of failing the launch.
            var lastOutcome: RemoteTmuxController.ShellMirrorSendOutcome = .notMirror
            for _ in 0..<20 {
                lastOutcome = await MainActor.run {
                    controller.sendShellCommandToMirror(
                        workspaceId: workspaceId, tmuxPane: paneParam, command: launchLine
                    )
                }
                if case .notMirror = lastOutcome {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                break
            }
            switch lastOutcome {
            case let .sent(pane):
                var result: [String: Any] = [
                    "workspace_id": workspaceId.uuidString,
                    "pane": pane,
                    "agent": entry.id,
                    "launched": launchLine,
                    "path": executable,
                    "host": detected.host.destination,
                    "host_kind": Self.amuxHostKind(detected.host.kind),
                ]
                if let sessionName { result["session"] = sessionName }
                if let prompt, !prompt.isEmpty, entry.promptInjection == .typeAfterStart {
                    let stream = await MainActor.run {
                        controller.mirrorPaneForegroundStream(
                            workspaceId: workspaceId,
                            tmuxPane: pane
                        )
                    }
                    let ready = if let stream {
                        await Self.waitForAgentPaneReady(stream, timeout: .seconds(15))
                    } else {
                        false
                    }
                    if ready {
                        let followup = await MainActor.run {
                            controller.guardedSendToMirror(
                                workspaceId: workspaceId,
                                tmuxPane: pane,
                                text: prompt,
                                enter: true,
                                guarded: true
                            )
                        }
                        if case .sent = followup {
                            result["prompt_sent"] = true
                        } else {
                            result["followup_prompt"] = prompt
                            result["prompt_sent"] = false
                        }
                    } else {
                        result["followup_prompt"] = prompt
                        result["prompt_sent"] = false
                    }
                }
                return .ok(result)
            case .notMirror:
                return .err(
                    code: "not_mirror",
                    message: String(localized: "socket.amux.notMirror", defaultValue: "Workspace is not a live tmux mirror"),
                    data: nil
                )
            case let .paneBusy(pane, foreground):
                var data: [String: Any] = ["pane": pane]
                if let foreground { data["foreground"] = foreground }
                return .err(
                    code: "pane_busy",
                    message: String(localized: "socket.amux.paneBusy", defaultValue: "Pane is already running an interactive application"),
                    data: data
                )
            }
        }
    }

    /// Waits for the launched process to replace the pane's shell. The timeout
    /// is the intended startup deadline (not a polling delay) and is injected so
    /// focused tests can use a short duration.
    nonisolated static func waitForAgentPaneReady(
        _ states: AsyncStream<RemoteTmuxPaneForegroundState>,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states where state.hasActiveCommand {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return false
                }
                return false
            }
            let ready = await group.next() ?? false
            group.cancelAll()
            return ready
        }
    }

    nonisolated private static func amuxHostKind(_ kind: RemoteTmuxHostKind) -> String {
        switch kind {
        case .ssh: "ssh"
        case .localDefault: "local_default"
        case .localAmux: "local_amux"
        }
    }

    /// `amux.new_session` — create a fresh amux tmux-backed workspace (new
    /// `-L amux` session + mirror). No params. Worker lane (awaits tmux).
    /// Returns `{session, workspace_id}`.
    nonisolated func v2AmuxNewSession(id: Any?, params _: [String: Any]) -> String {
        v2VmCall(id: id, timeoutSeconds: 30) {
            guard let (controller, manager) = await MainActor.run(body: {
                AppDelegate.shared.flatMap { app in app.tabManager.map { (app.remoteTmuxController, $0) } }
            }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let name = try await controller.createLocalAmuxWorkspace(into: manager)
            let workspaceId = await MainActor.run {
                controller.localMirrorWorkspace(sessionName: name)?.id.uuidString
            }
            return ["session": name, "workspace_id": workspaceId ?? ""]
        }
    }

    /// `amux.sessions` — list amux local-server sessions with a `mirrored`
    /// flag (the Detached-section data). No params. Worker lane.
    nonisolated func v2AmuxSessions(id: Any?, params _: [String: Any]) -> String {
        v2VmCall(id: id, timeoutSeconds: 15) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let sessions = try await controller.localAmuxSessions()
            return [
                "sessions": sessions.map { entry in
                    var payload = Self.sessionPayload(entry.session)
                    payload["mirrored"] = entry.mirrored
                    return payload
                },
            ]
        }
    }

    /// `amux.attach_session` — mirror a detached amux session as a
    /// workspace. Params: `session` (required). Worker lane. NOT
    /// focus-intent (mirror creation only; selection stays with the app's
    /// own new-workspace behavior).
    nonisolated func v2AmuxAttachSession(id: Any?, params: [String: Any]) -> String {
        guard let name = (params["session"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(localized: "socket.remoteTmux.sessionRequired", defaultValue: "session is required")
            )
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            // Verify the session actually exists on the amux server before
            // mirroring, so a typo'd/dead name fails cleanly instead of
            // leaving an orphan workspace whose control stream errors out.
            let sessions = try await controller.localAmuxSessions()
            guard sessions.contains(where: { $0.session.name == name }) else {
                throw RemoteTmuxError.commandFailed(exitCode: -1, stderr: "no such amux session: \(name)")
            }
            return try await MainActor.run {
                guard let appDelegate = AppDelegate.shared, let manager = appDelegate.tabManager else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                guard appDelegate.amuxAttachSession(
                    named: name,
                    in: manager,
                    focusWorkspace: false
                ) else {
                    throw RemoteTmuxError.commandFailed(exitCode: -1, stderr: "attach failed")
                }
                let workspaceId = appDelegate.remoteTmuxController
                    .localMirrorWorkspace(sessionName: name)?.id.uuidString
                return ["session": name, "workspace_id": workspaceId ?? ""]
            }
        }
    }

    /// `amux.close_kill` — close a mirror workspace AND kill its amux tmux
    /// session (opt-out of detach-by-default). Params: `workspace_id`
    /// (required). Main lane (UI mutation via v2MainSync).
    nonisolated func v2AmuxCloseKill(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            self.v2RefreshKnownRefs()
            guard let workspaceId = self.v2UUID(params, "workspace_id") else {
                return .err(code: "invalid_params", message: "workspace_id required", data: nil)
            }
            guard let appDelegate = AppDelegate.shared,
                  let workspace = appDelegate.amuxWorkspace(withId: workspaceId)?.workspace else {
                return .err(
                    code: "not_found",
                    message: String(localized: "socket.amux.workspaceNotFound", defaultValue: "Workspace not found"),
                    data: nil
                )
            }
            guard appDelegate.amuxCloseAndKillWorkspace(workspace) else {
                return .err(
                    code: "not_mirror",
                    message: String(localized: "socket.amux.notMirror", defaultValue: "Workspace is not a live tmux mirror"),
                    data: nil
                )
            }
            return .ok(["killed": true])
        }
    }

    /// `amux.attend` — jump to the agent that has been blocked on the user
    /// the longest: selects its workspace and focuses its tmux pane. An
    /// explicit focus-intent command under the socket focus policy — moving
    /// focus is its entire purpose (the analog of `workspace.select`).
    /// Returns `{attended: false}` when no tracked agent needs attention.
    nonisolated func v2AmuxAttend(params _: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let appDelegate = AppDelegate.shared else {
                return .err(
                    code: "unavailable",
                    message: String(localized: "socket.amux.appNotReady", defaultValue: "App is not ready"),
                    data: nil
                )
            }
            let attended = appDelegate.amuxAttend()
            return .ok(["attended": attended])
        }
    }

#if DEBUG
    /// `debug.amux.mirror_local` — DEBUG-only verification/dogfood entry for
    /// the amux Phase 0 spike: attach-or-create a session on the local
    /// `-L amux` tmux server and mirror it as a workspace. Same action path
    /// as the Debug menu item (both forward to
    /// `RemoteTmuxController.mirrorLocalAmuxSession`). Params: optional
    /// `session` (defaults to the shared spike session name).
    ///
    /// Runs the mutation on the main actor via `v2VmCall` because mirroring
    /// creates workspace/UI state; it selects nothing and raises no window,
    /// so it carries no focus intent (socket focus policy).
    nonisolated func v2AmuxMirrorLocal(id: Any?, params: [String: Any]) -> String {
        let session = (params["session"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? RemoteTmuxController.amuxSpikeSessionName
        return v2VmCall(id: id, timeoutSeconds: 30) {
            try await MainActor.run {
                guard let appDelegate = AppDelegate.shared,
                      let manager = appDelegate.tabManager else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                let mirrored = try appDelegate.remoteTmuxController.mirrorLocalAmuxSession(
                    sessionName: session,
                    into: manager
                )
                return ["session": session, "mirrored": mirrored]
            }
        }
    }

    /// `debug.amux.mirror_ssh` — DEBUG-only verification entry for the remote
    /// agent-observation slice: mirror ONE named session on an SSH host as a
    /// workspace (production `remote.tmux.mirror` mirrors every session on
    /// the host, which an E2E against a shared machine must not do). Params:
    /// `host` (required), `session` (required), optional `create` (Bool).
    ///
    /// Same focus posture as `debug.amux.mirror_local`: creates UI state on
    /// the main actor, selects nothing, raises no window.
    nonisolated func v2AmuxMirrorSSH(id: Any?, params: [String: Any]) -> String {
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: "host is required")
        }
        guard let session = (params["session"] as? String), !session.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "session is required")
        }
        let createIfMissing = (params["create"] as? Bool) ?? false
        return v2VmCall(id: id, timeoutSeconds: 60) {
            try await MainActor.run {
                guard let appDelegate = AppDelegate.shared,
                      let manager = appDelegate.tabManager else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                let mirrored = try appDelegate.remoteTmuxController.mirrorSession(
                    host: host,
                    sessionName: session,
                    createIfMissing: createIfMissing,
                    into: manager
                )
                return ["host": host.destination, "session": session, "mirrored": mirrored]
            }
        }
    }

    /// `debug.amux.parse_choices` — DEBUG-only verification for the
    /// waiting_choice sheet's capture→parse chain (the sheet itself is a
    /// modal NSAlert that can't be driven headlessly). Captures the
    /// workspace's agent pane and returns the parsed numbered options.
    /// Params: `workspace_id` (required UUID/ref).
    nonisolated func v2AmuxParseChoices(id: Any?, params: [String: Any]) -> String {
        let workspaceId: UUID? = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2UUID(params, "workspace_id")
        }
        guard let workspaceId else {
            return v2Error(id: id, code: "invalid_params", message: "workspace_id required")
        }
        return v2VmCall(id: id, timeoutSeconds: 15) {
            let agentPane = await MainActor.run {
                AppDelegate.shared?.amuxAgentObservation.agentPane(inWorkspace: workspaceId)
            }
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let text = await controller.captureMirrorPaneText(workspaceId: workspaceId, tmuxPane: agentPane)
            let choices = text.map(AmuxChoiceParser.parse) ?? []
            return [
                "choices": choices.map { ["number": $0.number, "label": $0.label] },
            ]
        }
    }
#endif
}
