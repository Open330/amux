import CmuxMuxa
import Foundation

/// Socket handlers for the amux agent-observation layer (badges, details,
/// remote-host provisioning).
extension TerminalController {
    /// `amux.agent_status` - the stable observation surface for every muxa
    /// agent correlated with a workspace. Omitting `workspace_id` targets the
    /// selected workspace, matching the pane-driving RPCs.
    @MainActor
    func v2AmuxAgentStatus(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2AmuxResolveWorkspaceId(params) else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.amux.workspaceNotFound",
                    defaultValue: "Workspace not found"
                ),
                data: nil
            )
        }
        guard let appDelegate = AppDelegate.shared else {
            return .err(
                code: "not_ready",
                message: String(
                    localized: "socket.amux.appNotReady",
                    defaultValue: "App is not ready"
                ),
                data: nil
            )
        }
        let agents = appDelegate.amuxAgentObservation.agents(inWorkspace: workspaceId)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "agents": agents.map(Self.amuxAgentPayload),
        ])
    }

    nonisolated static func amuxAgentPayload(_ agent: MuxaAgent) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": agent.kind.rawValue,
            "session_id": agent.sessionId,
            "state": agent.state.rawValue,
        ]
        payload["pane"] = agent.pane
        payload["tmux_session"] = agent.tmuxSession
        payload["cwd"] = agent.cwd
        payload["last_prompt"] = agent.lastPrompt
        payload["last_notification"] = agent.lastNotification
        payload["last_response"] = agent.lastResponse
        payload["model"] = agent.model
        payload["context_used_pct"] = agent.contextUsedPct
        payload["cost_usd"] = agent.costUsd
        payload["started_at"] = agent.startedAt
        payload["last_activity_at"] = agent.lastActivityAt
        payload["state_entered_at"] = agent.stateEnteredAt
        return payload
    }

    /// `amux.local_tmux_sync` — status/toggle for mirroring the user's default
    /// localhost tmux server into amux workspaces. Shared by the Command Palette
    /// toggle and the `amux sync tmux` CLI. Worker lane because status/sync may
    /// shell out to tmux.
    nonisolated func v2AmuxLocalTmuxSync(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        let action = (params["action"] as? String) ?? "sync"
        guard ["status", "sync", "unsync"].contains(action) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.amux.localTmuxSyncActionInvalid",
                    defaultValue: "action must be status, sync, or unsync"
                )
            )
        }
        return v2VmCall(id: id, timeoutSeconds: 45) {
            guard let app = await MainActor.run(body: { AppDelegate.shared }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            var discovered: Int?
            var mirrored: Int?
            if action == "sync" {
                guard let manager = await MainActor.run(body: { app.tabManager }) else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                let result = try await app.remoteTmuxController.mirrorLocalDefaultTmuxSessions(
                    into: manager
                )
                discovered = result.discovered
                mirrored = result.mirrored
                await MainActor.run {
                    app.amuxLocalTmuxSessionSyncEnabled = true
                }
            } else if action == "unsync" {
                await MainActor.run {
                    app.amuxLocalTmuxSessionSyncEnabled = false
                }
            }

            let sessions = (try? await app.remoteTmuxController.localDefaultTmuxSessions()) ?? []
            let enabled = await MainActor.run {
                app.amuxLocalTmuxSessionSyncEnabled
            }
            var payload: [String: Any] = [
                "host": "localhost",
                "enabled": enabled,
                "tmux_sessions": sessions.map {
                    var item = Self.sessionPayload($0.session)
                    item["mirrored"] = $0.mirrored
                    return item
                },
            ]
            if let discovered { payload["discovered"] = discovered }
            if let mirrored { payload["mirrored"] = mirrored }
            return payload
        }
    }

    /// `amux.remote_setup` — inspect (default) or provision the muxa
    /// observation stack on an SSH host: muxa CLI presence/version, muxad
    /// liveness, agent-hook wiring, and muxa's own notifier state. Params:
    /// `host` (required SSH destination; `port`/`identity_file` optional),
    /// optional `action` — `"inspect"` (default), `"wire"` (runs the
    /// hooks-only `muxa init` remotely, which also starts muxad when
    /// absent), `"sync"` (enable per-host tmux sync and mirror sessions), or
    /// `"unsync"` (disable future sync for this host). Worker lane (SSH round
    /// trips via v2VmCall). `sync` is not focus-intent by default; pass
    /// `activate: true` to bring the mirror window forward.
    nonisolated func v2AmuxRemoteSetup(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params), host.kind == .ssh else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let action = (params["action"] as? String) ?? "inspect"
        guard ["inspect", "wire", "sync", "unsync"].contains(action) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.amux.remoteSetupActionInvalid",
                    defaultValue: "action must be inspect, wire, sync, or unsync"
                )
            )
        }
        let activate = (params["activate"] as? Bool) ?? false
        return v2VmCall(id: id, timeoutSeconds: 120) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let setup = AmuxRemoteHostSetup()
            var wireOutput: String?
            if action == "wire" {
                wireOutput = try await setup.wireHooks(host: host)
            }
            var tmuxSessions: [RemoteTmuxSession]?
            var syncOutcome: [String: Any]?
            if action == "sync" {
                let outcome = try await controller.mirrorHostInNewWindow(
                    host: host,
                    activateWindow: activate
                )
                switch outcome {
                case .mirrored(let windowId):
                    await MainActor.run {
                        AppDelegate.shared?.amuxSetRemoteTmuxSyncEnabled(true, for: host)
                    }
                    tmuxSessions = try? await controller.listSessions(host: host)
                    syncOutcome = ["mirrored": true, "window_id": windowId.uuidString]
                case .authRequired(let sshArgv):
                    syncOutcome = ["auth_required": true, "ssh_argv": sshArgv]
                }
            } else if action == "unsync" {
                await MainActor.run {
                    AppDelegate.shared?.amuxSetRemoteTmuxSyncEnabled(false, for: host)
                }
                syncOutcome = ["mirrored": false]
                tmuxSessions = try? await controller.listSessions(host: host)
            } else {
                tmuxSessions = try? await controller.listSessions(host: host)
            }
            let authRequired = (syncOutcome?["auth_required"] as? Bool) == true
            let report: AmuxRemoteHostSetup.Report?
            if authRequired {
                report = try? await setup.inspect(host: host)
            } else {
                report = try await setup.inspect(host: host)
            }
            var payload: [String: Any] = [
                "host": host.destination,
                "muxa_installed": report?.muxaVersion != nil,
                "muxad_running": report?.muxadRunning ?? false,
                "claude_hooks": report?.claudeHooksWired ?? false,
                "codex_hooks": report?.codexHooksWired ?? false,
                "notifier_enabled": report?.notifierEnabled ?? false,
            ]
            payload["muxa_version"] = report?.muxaVersion
            payload["wire_output"] = wireOutput
            payload["tmux_sessions"] = (tmuxSessions ?? []).map { Self.sessionPayload($0) }
            payload["tmux_sync_enabled"] = await MainActor.run {
                AppDelegate.shared?.amuxRemoteTmuxSyncEnabled(for: host) ?? false
            }
            payload["sync"] = syncOutcome
            return payload
        }
    }

}
