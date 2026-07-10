import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for remote-tmux mirror targeting and lifecycle decisions. These
/// exercise pure seams and cached unstarted control connections; no ssh/tmux
/// process is launched.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorTargetingTests {
    private func session(_ name: String, id: String? = nil) -> RemoteTmuxSession {
        RemoteTmuxSession(
            id: id ?? "$\(name)",
            name: name,
            windowCount: 1,
            attached: false,
            createdUnix: nil
        )
    }

    private func cacheConnection(
        controller: RemoteTmuxController,
        host: RemoteTmuxHost,
        sessionName: String,
        sessionId: Int? = nil
    ) {
        controller.cacheConnection(RemoteTmuxControlConnection(
            host: host,
            sessionName: sessionName,
            sessionId: sessionId
        ))
    }

    @Test func unmirroredSessionsFiltersAlreadyMirroredNamesForHost() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        try controller.mirrorSession(host: host, sessionName: "old", into: manager)

        let sessions = [session("old"), session("new")]
        #expect(controller.unmirroredSessions(sessions, host: host).map(\.name) == ["new"])
    }

    @Test func tmuxSessionNumericIdParsesOnlyDollarPrefixedDecimalIds() {
        #expect(RemoteTmuxController.tmuxSessionNumericId("$0") == 0)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$42") == 42)
        #expect(RemoteTmuxController.tmuxSessionNumericId("0") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$x") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$-1") == nil)
    }

    @Test func unmirroredSessionsUsesStableSessionIdsBeforeNames() {
        // Rename race: the mirrored session's %session-renamed has not re-keyed
        // yet, so its stable id must prevent a duplicate mirror under the new name.
        let renameRace = RemoteTmuxController.unmirroredSessions(
            [session("zeromain", id: "$0")],
            mirroredSessionIds: [0],
            mirroredNames: ["0"],
            idlessMirroredNames: []
        )
        #expect(renameRace.isEmpty)

        // A NEW session reusing a mirrored session's stale pre-rename name is a
        // distinct attach target because its stable id differs.
        let reusedOldName = RemoteTmuxController.unmirroredSessions(
            [session("0", id: "$5")],
            mirroredSessionIds: [0],
            mirroredNames: ["0"],
            idlessMirroredNames: []
        )
        #expect(reusedOldName.map(\.name) == ["0"])

        // Mid-attach mirrors have no sessionId yet; the name fallback covers them.
        let midAttach = RemoteTmuxController.unmirroredSessions(
            [session("dev", id: "$5")],
            mirroredSessionIds: [],
            mirroredNames: ["dev"],
            idlessMirroredNames: ["dev"]
        )
        #expect(midAttach.isEmpty)

        let fresh = RemoteTmuxController.unmirroredSessions(
            [session("fresh", id: "$7")],
            mirroredSessionIds: [0],
            mirroredNames: ["old"],
            idlessMirroredNames: []
        )
        #expect(fresh.map(\.name) == ["fresh"])
    }

    @Test func unmirroredSessionsSeesSeededSessionIdBeforeStreamReportsIt() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        try controller.mirrorSession(host: host, sessionName: "old", sessionId: 3, into: manager)

        // Renamed remotely before %session-changed re-keys: same $3, new name —
        // the discovery-seeded id must prevent a duplicate mirror.
        #expect(controller.unmirroredSessions([session("renamed", id: "$3")], host: host).isEmpty)
        // A genuinely new session is still discovered.
        #expect(controller.unmirroredSessions([session("fresh", id: "$4")], host: host).map(\.name) == ["fresh"])
    }

    @Test func mirrorSessionsMirrorsOnlyNewSessionsAndIsIdempotent() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        cacheConnection(controller: controller, host: host, sessionName: "new")
        try controller.mirrorSession(host: host, sessionName: "old", into: manager)

        controller.mirrorSessions([session("old"), session("new")], host: host, into: manager)
        controller.mirrorSessions([session("old"), session("new")], host: host, into: manager)

        let mirrorTitles = manager.tabs
            .filter(\.isRemoteTmuxMirror)
            .map(\.title)
            .sorted()
        #expect(mirrorTitles == ["new", "old"])
    }

    @Test func firstStableSessionIdRekeysMirrorAndConnectionTogether() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        controller.cacheConnection(connection)
        try controller.mirrorSession(host: host, sessionName: "work", into: manager)

        connection.handleMessageForTesting(.sessionChanged(sessionId: 12, name: "work"))
        #expect(connection.attachTarget == "$12")

        controller.detach(host: host, sessionName: "work")
        #expect(controller.connection(host: host, sessionName: "work") == nil)
        #expect(!manager.tabs.contains { $0.isRemoteTmuxMirror })
    }

    @Test func mirrorTargetTabManagerPrefersDedicatedWindowWhenResolvable() {
        let dedicatedId = UUID()
        let dedicated = TabManager()
        let fallback = TabManager()

        let resolved = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: dedicatedId,
            tabManagerForWindow: { $0 == dedicatedId ? dedicated : nil },
            fallbackTabManager: { fallback }
        )

        #expect(resolved === dedicated)
    }

    @Test func mirrorTargetTabManagerFallsBackWhenDedicatedMissingOrUnresolved() {
        let dedicatedId = UUID()
        let fallback = TabManager()

        let missing = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: nil,
            tabManagerForWindow: { _ in nil },
            fallbackTabManager: { fallback }
        )
        let unresolved = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: dedicatedId,
            tabManagerForWindow: { _ in nil },
            fallbackTabManager: { fallback }
        )

        #expect(missing === fallback)
        #expect(unresolved === fallback)
    }

    @Test func backgroundSessionAttachDoesNotActivateWindow() {
        let manager = TabManager()
        var activatedManagers: [TabManager] = []

        AppDelegate.activateWindowAfterSessionAttach(
            ifRequested: false,
            owner: manager,
            bringForward: { activatedManagers.append($0) }
        )
        #expect(activatedManagers.isEmpty)

        AppDelegate.activateWindowAfterSessionAttach(
            ifRequested: true,
            owner: manager,
            bringForward: { activatedManagers.append($0) }
        )
        #expect(activatedManagers.count == 1)
        #expect(activatedManagers.first === manager)
    }

    @Test func sessionSwitcherAttachUsesHostDedicatedWindow() throws {
        let previousDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousDelegate }

        let host = RemoteTmuxHost(destination: "builder@example.com")
        let dedicatedManager = TabManager()
        let fallbackManager = TabManager()
        let dedicatedWindowId = app.registerMainWindowContextForTesting(tabManager: dedicatedManager)
        defer {
            app.remoteTmuxController.detachAll()
            app.unregisterMainWindowContextForTesting(windowId: dedicatedWindowId)
        }
        app.remoteTmuxController.bindDedicatedWindowForTesting(host: host, windowId: dedicatedWindowId)
        cacheConnection(
            controller: app.remoteTmuxController,
            host: host,
            sessionName: "agent-work",
            sessionId: 9
        )

        let attached = app.amuxAttachSession(
            host: host,
            session: session("agent-work", id: "$9"),
            in: fallbackManager
        )

        #expect(attached)
        #expect(dedicatedManager.tabs.contains { $0.isRemoteTmuxMirror && $0.title == "agent-work" })
        #expect(!fallbackManager.tabs.contains { $0.isRemoteTmuxMirror })
        #expect(dedicatedManager.selectedWorkspace?.title == "agent-work")
        #expect(app.remoteTmuxController.connection(
            host: host,
            sessionName: "agent-work"
        )?.attachTarget == "$9")
    }

    @Test func workspaceCloseDetachesByDefaultOnSSH() {
        // Plain close must never kill the remote session: ssh mirrors promise
        // detach-by-default exactly like the amux local engine (closing a
        // workspace while a remote agent runs must not end its session).
        // Only the explicit force-kill ("Close and Kill") ends the session.
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: 5,
            sessionName: "dev",
            hostKind: .ssh,
            forceKill: false
        ) == nil)
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: 5,
            sessionName: "dev",
            hostKind: .ssh,
            forceKill: true
        ) == "$5")
    }

    @Test func workspaceCloseKillTargetSkipsEndedConnections() {
        // Even an explicit force-kill has nothing to kill once the control
        // client ended; live connections resolve the id-first target.
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: true,
            sessionId: 5,
            sessionName: "dev",
            forceKill: true
        ) == nil)
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: 5,
            sessionName: "dev",
            forceKill: true
        ) == "$5")
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: nil,
            sessionName: "dev",
            forceKill: true
        ) == "dev")
    }

    @Test func shouldRefreshTitleChromeDistinguishesDirectAndSurfaceSourcedNotifications() throws {
        let suiteName = "RemoteTmuxMirrorTargeting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let selected = try #require(manager.selectedWorkspace)
        manager.selectedTabId = selected.id
        let otherId = UUID()
        let directSelected = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [GhosttyNotificationKey.tabId: selected.id]
        )
        let directOther = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [GhosttyNotificationKey.tabId: otherId]
        )
        let surfaceSelected = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [
                GhosttyNotificationKey.tabId: selected.id,
                GhosttyNotificationKey.surfaceId: UUID(),
            ]
        )

        settings.set(false, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(!manager.shouldRefreshTitleChrome(for: directOther))
        #expect(manager.shouldRefreshTitleChrome(for: directSelected))
        #expect(!manager.shouldRefreshTitleChrome(for: surfaceSelected))

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(manager.shouldRefreshTitleChrome(for: directSelected))
        #expect(manager.shouldRefreshTitleChrome(for: surfaceSelected))
    }
}
