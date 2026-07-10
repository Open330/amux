import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror split routing contract
/// (https://github.com/manaflow-ai/cmux/pull/5553): a split request on a
/// remote tmux mirror workspace must never create a local panel — it is
/// routed to the remote tmux session (the pane arrives via %layout-change),
/// or fails when no live mirror exists. A local panel here would be an
/// orphan the mirror's rebuild() never reconciles, and the socket layer
/// reporting routed requests as errors makes automation retry and duplicate
/// remote panes.
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorSplitRoutingTests {
    @Test func mirrorWorkspaceSplitNeverCreatesLocalPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.isRemoteTmuxMirror = true
        let panelsBefore = harness.workspace.panels.count

        let panel = harness.workspace.newTerminalSplit(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        #expect(panel == nil)
        #expect(harness.workspace.panels.count == panelsBefore)
    }

    @Test func localWorkspaceSplitStillCreatesLocalPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let panelsBefore = harness.workspace.panels.count

        let panel = harness.workspace.newTerminalSplit(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        #expect(panel != nil)
        #expect(harness.workspace.panels.count == panelsBefore + 1)
    }

    @Test func windowMirrorSplitRejectsWhileConnecting() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7)),
            makePanel: { _ in nil }
        )

        #expect(!mirror.requestSplit(fromPane: 7, vertical: true))
    }

    @Test func windowMirrorSeedsAndFollowsTmuxActivePane() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 8))
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(
                width: 120,
                height: 40,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 60, height: 40, x: 0, y: 0, content: .pane(7)),
                    RemoteTmuxLayoutNode(width: 60, height: 40, x: 60, y: 0, content: .pane(8)),
                ])
            ),
            makePanel: { _ in nil }
        )

        #expect(mirror.activePaneId == 8)

        mirror.noteTmuxActivePane(7)
        #expect(mirror.activePaneId == 7)

        mirror.noteTmuxActivePane(99)
        #expect(mirror.activePaneId == 7)
    }

    @Test func windowMirrorMovesActivePaneWhenLayoutPrunesOldPane() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(
                width: 120,
                height: 40,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 60, height: 40, x: 0, y: 0, content: .pane(7)),
                    RemoteTmuxLayoutNode(width: 60, height: 40, x: 60, y: 0, content: .pane(8)),
                ])
            ),
            makePanel: { _ in nil }
        )

        mirror.noteTmuxActivePane(8)
        mirror.reconcile(fullLayout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7)))

        #expect(mirror.activePaneId == 7)
    }

    @Test func workspaceRecognizesActiveMirrorChildPaneAsFocusTarget() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.isRemoteTmuxMirror = true
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 7))
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: harness.sourcePanelId,
            connection: connection,
            layout: RemoteTmuxLayoutNode(
                width: 120,
                height: 40,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 60, height: 40, x: 0, y: 0, content: .pane(7)),
                    RemoteTmuxLayoutNode(width: 60, height: 40, x: 60, y: 0, content: .pane(8)),
                ])
            ),
            makePanel: { paneId in
                harness.workspace.makeRemoteTmuxPanePanel(onInput: { _ in })
            }
        )
        defer {
            harness.workspace.setRemoteTmuxWindowMirror(nil, forPanelId: harness.sourcePanelId)
            mirror.teardown()
        }
        harness.workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: harness.sourcePanelId)

        let pane7Panel = try #require(mirror.panel(forPane: 7))
        let pane8Panel = try #require(mirror.panel(forPane: 8))

        #expect(harness.workspace.isCurrentRemoteTmuxMirrorChildFocusTarget(panelId: pane7Panel.id))
        #expect(!harness.workspace.isCurrentRemoteTmuxMirrorChildFocusTarget(panelId: pane8Panel.id))

        mirror.noteTmuxActivePane(8)

        #expect(!harness.workspace.isCurrentRemoteTmuxMirrorChildFocusTarget(panelId: pane7Panel.id))
        #expect(harness.workspace.isCurrentRemoteTmuxMirrorChildFocusTarget(panelId: pane8Panel.id))
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let sourcePanelId: UUID

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            sourcePanelId = try #require(workspace.focusedPanelId)
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}

/// The mirrored window's client-grid math: the size reported to tmux must
/// subtract the per-pane header bars and split dividers, or tmux allocates rows
/// the surfaces can't render and every pane clips its bottom row(s) — the core
/// "multi-pane windows don't mirror faithfully" defect.
struct RemoteTmuxMirrorGridMathTests {
    private let cell = CGSize(width: 8, height: 16)
    private let header = RemoteTmuxPaneHeader.height // 24
    private let divider = RemoteTmuxMirrorGridMath.dividerThickness // 2

    private func pane(_ id: Int, width: Int = 80, height: Int = 24) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(width: width, height: height, x: 0, y: 0, content: .pane(id))
    }

    @Test func singlePaneSubtractsOnlyItsHeader() {
        // 640×424 content: 424 - 24 header = 400 → 25 rows; 640/8 = 80 cols.
        let grid = RemoteTmuxMirrorGridMath.clientGrid(
            for: pane(1),
            contentSize: CGSize(width: 640, height: 424),
            cell: cell
        )
        #expect(grid.columns == 80)
        #expect(grid.rows == 25)
    }

    @Test func verticalStackSubtractsBothHeadersAndCountsSeparatorRow() {
        // Two stacked panes in 640×450: usable = 450 - 2 (divider) = 448, split
        // evenly → 224 px each → (224-24)/16 = 12 rows per pane → report
        // 12+12+1 (tmux separator row) = 25 rows. The old raw math reported
        // floor(450/16) = 28 — three rows tmux allocated but the surfaces
        // couldn't show.
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 49, x: 0, y: 0,
            content: .vertical([pane(1, height: 24), pane(2, height: 24)])
        )
        let grid = RemoteTmuxMirrorGridMath.clientGrid(
            for: layout,
            contentSize: CGSize(width: 640, height: 450),
            cell: cell
        )
        #expect(grid.rows == 25)
        #expect(grid.columns == 80)
    }

    @Test func horizontalSplitSubtractsHeaderOnceAndCountsSeparatorColumn() {
        // Side-by-side panes: rows lose ONE header (they don't stack); columns
        // split across the divider with tmux's 1-cell separator added back.
        // 642×424: rows = (424-24)/16 = 25; cols: usable = 642-2 = 640, even
        // split → 320 px → 40 cols each → 40+40+1 = 81.
        let layout = RemoteTmuxLayoutNode(
            width: 81, height: 24, x: 0, y: 0,
            content: .horizontal([pane(1, width: 40), pane(2, width: 40)])
        )
        let grid = RemoteTmuxMirrorGridMath.clientGrid(
            for: layout,
            contentSize: CGSize(width: 642, height: 424),
            cell: cell
        )
        #expect(grid.rows == 25)
        #expect(grid.columns == 81)
    }

    @Test func nestedSplitUsesDeepestChromeOnEachAxis() {
        // Left: single pane. Right: two stacked panes. Rows are limited by the
        // right column's double chrome: usable right = 450-2 = 448 → 224 px per
        // stacked pane → 12 rows each → right supports 12+12+1 = 25; left alone
        // would support (450-24)/16 = 26 → min is 25.
        let layout = RemoteTmuxLayoutNode(
            width: 161, height: 49, x: 0, y: 0,
            content: .horizontal([
                pane(1, width: 80, height: 49),
                RemoteTmuxLayoutNode(
                    width: 80, height: 49, x: 81, y: 0,
                    content: .vertical([pane(2, height: 24), pane(3, height: 24)])
                ),
            ])
        )
        let rows = RemoteTmuxMirrorGridMath.maxRows(
            for: layout, availableHeight: 450, cellHeight: cell.height
        )
        #expect(rows == 25)
    }

    @Test func childPixelSpansGiveEachPaneItsCellAllocation() {
        // 2:1 vertical split of 36 rows (24 + 11 + separator) rendered into the
        // exact pixel need: each child must get exactly cells×cellHeight+header.
        let children = [pane(1, height: 24), pane(2, height: 11)]
        let needTop = 24 * cell.height + header
        let needBottom = 11 * cell.height + header
        let spans = RemoteTmuxMirrorGridMath.childPixelSpans(
            children: children,
            horizontalAxis: false,
            usable: needTop + needBottom,
            cell: cell
        )
        #expect(spans == [needTop, needBottom])
    }

    @Test func childPixelSpansDistributeSlackProportionally() {
        let children = [pane(1, height: 20), pane(2, height: 20)]
        let need = 20 * cell.height + header
        let spans = RemoteTmuxMirrorGridMath.childPixelSpans(
            children: children,
            horizontalAxis: false,
            usable: need * 2 + 10,
            cell: cell
        )
        #expect(spans.count == 2)
        #expect(abs(spans[0] - (need + 5)) < 0.001)
        #expect(abs(spans[1] - (need + 5)) < 0.001)
    }

    @Test func childPixelSpansFallBackToProportionsWithoutCellSize() {
        let children = [pane(1, height: 30), pane(2, height: 10)]
        let spans = RemoteTmuxMirrorGridMath.childPixelSpans(
            children: children,
            horizontalAxis: false,
            usable: 400,
            cell: nil
        )
        #expect(spans == [300, 100])
    }
}
