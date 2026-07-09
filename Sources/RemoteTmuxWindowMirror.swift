import AppKit
import Bonsplit
import CmuxTerminal
import Foundation
import Observation

/// Owns the per-pane ``TerminalPanel``s and current layout for ONE mirrored tmux
/// window, so a single cmux tab can render the tmux window's full multi-pane
/// split layout side by side — with the native cmux pane chrome (each pane is a
/// real ``TerminalPanel`` rendered via ``TerminalPanelView``).
///
/// Created lazily by ``RemoteTmuxSessionMirror`` the first time a window has more
/// than one pane; once created it owns every pane's panel for that window. The
/// remote tmux control stream is the source of truth: pane output is fed into
/// the matching surface, typed input is forwarded to that pane via `send-keys`,
/// and a user split is propagated to `split-window`.
@MainActor
@Observable
final class RemoteTmuxWindowMirror {
    /// tmux window id (the `@N` without the sigil).
    let windowId: Int
    /// The bonsplit tab's panel id this window renders into.
    let panelId: UUID

    @ObservationIgnored private weak var connection: RemoteTmuxControlConnection?
    /// Creates a configured manual-I/O pane panel whose input goes to `tmuxPaneId`.
    @ObservationIgnored private let makePanel: (_ tmuxPaneId: Int) -> TerminalPanel?

    /// The layout to RENDER — drives the SwiftUI split container. While a pane
    /// is zoomed this is tmux's visible layout (that single pane, full window);
    /// otherwise it equals ``fullLayout``.
    private(set) var layout: RemoteTmuxLayoutNode
    /// The window's FULL pane topology. Panel lifecycle keys off this, so the
    /// panes hidden behind a zoom keep their panels (and scrollback) instead of
    /// being torn down on every zoom toggle.
    @ObservationIgnored private(set) var fullLayout: RemoteTmuxLayoutNode
    /// The tmux pane the user last focused (drives the focus overlay + splits).
    private(set) var activePaneId: Int?

    /// ``TerminalPanel`` per tmux pane id. Not observation-tracked: the view
    /// re-reads it whenever ``layout`` (which IS tracked) changes, and the two
    /// are always updated together in ``reconcile(layout:)``.
    @ObservationIgnored private var panelsByPaneId: [Int: TerminalPanel] = [:]
    /// Stable synthetic bonsplit pane id per tmux pane (for portal hosting),
    /// minted at panel-creation time so the view body is a pure read.
    @ObservationIgnored private var syntheticPaneIds: [Int: PaneID] = [:]

    /// Panels handed over at creation time (keyed by tmux pane id): the
    /// window's original single-pane DISPLAY panel is adopted as that pane's
    /// mirror panel, so the first split preserves its live surface and
    /// scrollback instead of re-seeding from a `capture-pane` snapshot.
    /// Consumed by the first ``reconcile``; leftovers (pane already gone) are
    /// closed.
    @ObservationIgnored private var pendingAdoptedPanels: [Int: TerminalPanel]

    init(
        windowId: Int,
        panelId: UUID,
        connection: RemoteTmuxControlConnection,
        layout: RemoteTmuxLayoutNode,
        renderedLayout: RemoteTmuxLayoutNode? = nil,
        adoptedPanels: [Int: TerminalPanel] = [:],
        makePanel: @escaping (_ tmuxPaneId: Int) -> TerminalPanel?
    ) {
        self.windowId = windowId
        self.panelId = panelId
        self.connection = connection
        self.makePanel = makePanel
        self.pendingAdoptedPanels = adoptedPanels
        self.fullLayout = layout
        self.layout = renderedLayout ?? layout
        reconcile(fullLayout: layout, renderedLayout: renderedLayout ?? layout)
    }

    /// All tmux pane ids currently in the window (including panes hidden
    /// behind a zoom), depth-first left→right.
    var paneIDsInOrder: [Int] { fullLayout.paneIDsInOrder }

    /// The panel rendering `tmuxPaneId`, if it exists.
    func panel(forPane tmuxPaneId: Int) -> TerminalPanel? { panelsByPaneId[tmuxPaneId] }

    /// The surface rendering `tmuxPaneId`, if it exists.
    func surface(forPane tmuxPaneId: Int) -> TerminalSurface? { panelsByPaneId[tmuxPaneId]?.surface }

    /// Whether `panelId` belongs to one of this tmux window's child pane surfaces.
    func containsPanel(_ panelId: UUID) -> Bool {
        panelsByPaneId.values.contains { $0.id == panelId }
    }

    /// Whether `panelId` is the child pane surface that should currently own
    /// terminal keyboard focus for this mirrored tmux window.
    func isActivePanel(_ panelId: UUID) -> Bool {
        guard let activePaneId,
              let panel = panelsByPaneId[activePaneId] else { return false }
        return panel.id == panelId
    }

    /// The stable synthetic bonsplit pane id for `tmuxPaneId`, or `nil` if no panel
    /// exists for it (minted in ``reconcile(layout:)``; a pure read here so it's
    /// body-safe). Returns `nil` rather than minting a throwaway `PaneID()` on a miss,
    /// which would churn the portal-host lease keyed off this id.
    func syntheticPaneID(forPane tmuxPaneId: Int) -> PaneID? {
        syntheticPaneIds[tmuxPaneId]
    }

    /// Updates the layout, creating panels for new panes and tearing down panels
    /// for panes tmux removed (surviving panes keep their panel and scrollback).
    /// Panel lifecycle keys off `newFullLayout`; the split container renders
    /// `newRenderedLayout` (they differ only while a pane is zoomed, so zoom
    /// toggles never destroy the hidden panes' panels). A layout change also
    /// changes the chrome overhead (one header bar per pane), so the client grid
    /// is re-derived from the remembered content size.
    func reconcile(fullLayout newFullLayout: RemoteTmuxLayoutNode, renderedLayout newRenderedLayout: RemoteTmuxLayoutNode? = nil) {
        let newRendered = newRenderedLayout ?? newFullLayout
        let previousRendered = layout
        defer {
            if previousRendered != newRendered, let size = lastContentSizePoints {
                updateClientSize(contentSizePoints: size)
            }
        }
        fullLayout = newFullLayout
        let livePaneIds = Set(newFullLayout.paneIDsInOrder)
        for paneId in newFullLayout.paneIDsInOrder where panelsByPaneId[paneId] == nil {
            // Adoption first: the window's original display panel is already
            // live and painted for this pane — reuse it (keeping its surface
            // and scrollback) instead of minting a fresh panel and re-seeding
            // from a capture-pane snapshot.
            if let adopted = pendingAdoptedPanels.removeValue(forKey: paneId) {
                panelsByPaneId[paneId] = adopted
                syntheticPaneIds[paneId] = PaneID()
                continue
            }
            guard let panel = makePanel(paneId) else { continue }
            panelsByPaneId[paneId] = panel
            syntheticPaneIds[paneId] = PaneID()
            // Backlog overflow discards the buffered stream whole; re-seed from
            // tmux so the first paint is the true screen (see
            // ``TerminalSurface/onRemoteOutputOverflowReseed``).
            panel.surface.onRemoteOutputOverflowReseed = { [weak connection] in
                connection?.seedPane(paneId: paneId)
            }
            // Canonical seed (reflow classification → capture → cwd). The session
            // mirror's cwd observer maps the pane back to this window's tab.
            connection?.seedPane(paneId: paneId)
        }
        // An adopted panel whose pane vanished before this reconcile has no
        // owner left — close it rather than leak the live surface.
        if !pendingAdoptedPanels.isEmpty {
            for panel in pendingAdoptedPanels.values { panel.close() }
            pendingAdoptedPanels.removeAll()
        }
        for (paneId, panel) in panelsByPaneId where !livePaneIds.contains(paneId) {
            // Use the full panel close (detaches the portal from the registry
            // BEFORE freeing the surface) so a stale portal entry can't be
            // dereferenced by a later Core Animation commit.
            panel.close()
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
            panelsByPaneId[paneId] = nil
            syntheticPaneIds[paneId] = nil
        }
        if let activePaneId, !livePaneIds.contains(activePaneId) {
            self.activePaneId = nil
        }
        if activePaneId == nil {
            if let tmuxActive = connection?.activePaneByWindow[windowId],
               livePaneIds.contains(tmuxActive) {
                activePaneId = tmuxActive
            } else {
                activePaneId = newRendered.paneIDsInOrder.first
            }
        }
        if layout != newRendered { layout = newRendered }
    }

    /// Routes a tmux `%output` to the surface for `paneId` (no-op if unknown).
    func routeOutput(paneId: Int, data: Data) {
        panelsByPaneId[paneId]?.surface.processRemoteOutput(data)
    }

    @ObservationIgnored private var lastClientSize: (cols: Int, rows: Int)?
    /// Last rendered content area, remembered so a LAYOUT change (split/close —
    /// which changes the chrome overhead) can recompute the client grid without
    /// waiting for the next geometry change.
    @ObservationIgnored private var lastContentSizePoints: CGSize?

    /// The cell size of any live pane surface (they all share one font/grid), or
    /// `nil` while none has rendered yet. Shared by the client-grid math and the
    /// split renderer's cell-exact child allocation.
    func referenceCellSize() -> CGSize? {
        guard let cell = panelsByPaneId.values.lazy.compactMap({ $0.surface.cellSizePoints() }).first,
              cell.width > 1, cell.height > 1 else { return nil }
        return CGSize(width: cell.width, height: cell.height)
    }

    /// Tells tmux to size this session's windows to the rendered cmux area, so
    /// captured/live pane content matches the on-screen grid. Derives cols/rows
    /// from the content pixel area and a live pane's cell size — SUBTRACTING the
    /// per-pane chrome (each pane's header bar and the split dividers) via the
    /// layout tree (``RemoteTmuxMirrorGridMath``). Reporting the raw area let
    /// tmux allocate rows the chrome had already consumed, so every pane in a
    /// multi-pane window rendered 1–2 rows short (prompt / TUI status line
    /// clipped). Sends `refresh-client -C` only when the grid actually changes
    /// (no feedback loop: the cmux area doesn't change when tmux reflows).
    /// Returns `true` once the pane surface is live and the size was applied (sent, or
    /// already current via the `lastClientSize` dedup); `false` when no pane has
    /// reported its cell size yet, so the caller should retry. Idempotent.
    @discardableResult
    func updateClientSize(contentSizePoints: CGSize) -> Bool {
        lastContentSizePoints = contentSizePoints
        guard contentSizePoints.width > 1, contentSizePoints.height > 1,
              let cell = referenceCellSize() else { return false }
        let grid = RemoteTmuxMirrorGridMath.clientGrid(
            for: layout, contentSize: contentSizePoints, cell: cell
        )
        guard lastClientSize?.cols != grid.columns || lastClientSize?.rows != grid.rows else { return true }
        lastClientSize = (grid.columns, grid.rows)
        connection?.setClientSize(columns: grid.columns, rows: grid.rows)
        return true
    }

    /// The pane panel socket I/O should target for this window: the mirror's
    /// focused pane when known, else the connection's tracked tmux-active
    /// pane (seeded from the attach-time `list-windows` snapshot), else the
    /// lowest pane id as a last resort.
    var socketTargetPanel: TerminalPanel? {
        if let active = activePaneId, let panel = panelsByPaneId[active] {
            return panel
        }
        if let tmuxActive = connection?.activePaneByWindow[windowId],
           let panel = panelsByPaneId[tmuxActive] {
            return panel
        }
        return panelsByPaneId.min(by: { $0.key < $1.key })?.value
    }

    /// Records the user-focused pane and asks tmux to make it active.
    func focus(pane tmuxPaneId: Int) {
        if activePaneId != tmuxPaneId { activePaneId = tmuxPaneId }
        if connection?.activePaneByWindow[windowId] != tmuxPaneId {
            connection?.send("select-pane -t @\(windowId).%\(tmuxPaneId)")
        }
    }

    /// Applies tmux's authoritative active-pane notification without echoing a
    /// `select-pane` command back into the control stream.
    func noteTmuxActivePane(_ tmuxPaneId: Int) {
        guard paneIDsInOrder.contains(tmuxPaneId) else { return }
        if activePaneId != tmuxPaneId { activePaneId = tmuxPaneId }
    }

    /// Propagates a user split of `tmuxPaneId` to tmux `split-window`
    /// (`-h` = side-by-side, `-v` = stacked). The new pane arrives via the
    /// resulting `%layout-change` → ``reconcile(layout:)``.
    @discardableResult
    func requestSplit(fromPane tmuxPaneId: Int, vertical: Bool) -> Bool {
        guard let connection, connection.connectionState == .connected else { return false }
        return connection.send("split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(tmuxPaneId)")
    }

    /// Propagates a user close of `tmuxPaneId` to tmux `kill-pane`. The pane is
    /// removed via the resulting `%layout-change` (or `%window-close` if it was
    /// the window's last pane).
    func requestKillPane(_ tmuxPaneId: Int) {
        connection?.send("kill-pane -t @\(windowId).%\(tmuxPaneId)")
    }

    /// The pane's last-known foreground classification (alt-screen flag +
    /// `pane_current_command`), driving the kill-pane close confirmation.
    /// `nil` when the pane was never classified (closes without a dialog).
    func paneForegroundState(_ tmuxPaneId: Int) -> RemoteTmuxControlConnection.PaneForegroundState? {
        connection?.paneForegroundStates[tmuxPaneId]
    }

    /// Live, close-time query of `tmuxPaneId`'s foreground state (see
    /// ``RemoteTmuxControlConnection/queryPaneActivity(paneId:completion:)``).
    /// Completes with `nil` when the connection is gone — the caller falls back
    /// to ``paneForegroundState(_:)``.
    func queryPaneActivity(
        _ tmuxPaneId: Int,
        completion: @escaping ([Int: RemoteTmuxControlConnection.PaneForegroundState]?) -> Void
    ) {
        guard let connection else {
            completion(nil)
            return
        }
        connection.queryPaneActivity(paneId: tmuxPaneId, completion: completion)
    }

    /// Tears down every pane panel (called when the window-tab is removed).
    func teardown() {
        // Unsubscribe each pane's cwd subscription first — matching reconcile(layout:),
        // which unsubscribes per removed pane. Without this, a control connection that
        // outlives the tab keeps streaming pane_current_path updates into a dead mirror.
        for paneId in panelsByPaneId.keys {
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
        }
        for panel in panelsByPaneId.values { panel.close() }
        panelsByPaneId.removeAll()
        syntheticPaneIds.removeAll()
        activePaneId = nil
    }
}

/// Pure grid math for a mirrored multi-pane tmux window.
///
/// The mirror renders each tmux pane as `[header bar][terminal surface]` with a
/// divider between split children, so the pixel area available for terminal
/// CELLS is the content area MINUS that chrome — and the chrome is non-uniform:
/// header bars stack along vertical splits, dividers along both axes, and the
/// overhead differs per subtree. These functions walk the tmux layout tree to
/// answer the two directions of that conversion:
///
/// - ``clientGrid(for:contentSize:cell:)``: the largest client `cols×rows` tmux
///   may be told (`refresh-client -C`) such that every pane's allocation still
///   fits its rendered surface. Over-reporting here is THE classic multi-pane
///   mangle: tmux streams rows/cols the surfaces can't show, clipping the
///   bottom row(s) (shell prompt, TUI status line) of every pane.
/// - ``pixelNeedHeight(of:cell:)`` / ``pixelNeedWidth(of:cell:)``: the exact
///   pixels a subtree needs to render its tmux-allocated cells plus chrome —
///   used by the split renderer so each pane surface gets AT LEAST its tmux
///   cell allocation (pixel-proportional splitting drifted a cell or more per
///   pane against tmux's cell-based division).
enum RemoteTmuxMirrorGridMath {
    /// Divider thickness between split children (must match
    /// ``RemoteTmuxLayoutContainer``'s spacing).
    nonisolated static let dividerThickness: CGFloat = 2

    /// The client grid to report to tmux for `layout` rendered into
    /// `contentSize` with `cell`-sized terminal cells. Floors keep degenerate
    /// windows sane for tmux (`refresh-client -C` rejects tiny grids poorly).
    nonisolated static func clientGrid(
        for layout: RemoteTmuxLayoutNode,
        contentSize: CGSize,
        cell: CGSize,
        headerHeight: CGFloat = RemoteTmuxPaneHeader.height
    ) -> (columns: Int, rows: Int) {
        (
            columns: max(20, maxColumns(for: layout, availableWidth: contentSize.width, cellWidth: cell.width)),
            rows: max(5, maxRows(
                for: layout, availableHeight: contentSize.height,
                cellHeight: cell.height, headerHeight: headerHeight
            ))
        )
    }

    /// The largest row count (in tmux's window coordinates, INCLUDING the one
    /// separator row tmux reserves between vertical split children) whose
    /// allocation fits `availableHeight`. Pixels are distributed to vertical
    /// children proportional to their current tmux extents — the same ratio
    /// tmux itself preserves when resizing a window.
    nonisolated static func maxRows(
        for node: RemoteTmuxLayoutNode,
        availableHeight: CGFloat,
        cellHeight: CGFloat,
        headerHeight: CGFloat = RemoteTmuxPaneHeader.height
    ) -> Int {
        guard cellHeight > 0 else { return 1 }
        switch node.content {
        case .pane:
            return max(1, Int((availableHeight - headerHeight) / cellHeight))
        case let .horizontal(children):
            return children.map {
                maxRows(for: $0, availableHeight: availableHeight, cellHeight: cellHeight, headerHeight: headerHeight)
            }.min() ?? 1
        case let .vertical(children):
            let usable = availableHeight - dividerThickness * CGFloat(max(0, children.count - 1))
            let totalCells = CGFloat(max(1, children.reduce(0) { $0 + $1.height }))
            let childRows = children.reduce(0) { sum, child in
                sum + maxRows(
                    for: child,
                    availableHeight: usable * CGFloat(child.height) / totalCells,
                    cellHeight: cellHeight,
                    headerHeight: headerHeight
                )
            }
            return childRows + max(0, children.count - 1)
        }
    }

    /// Column counterpart of ``maxRows`` (no header on the horizontal axis;
    /// tmux reserves one separator column between horizontal split children).
    nonisolated static func maxColumns(
        for node: RemoteTmuxLayoutNode,
        availableWidth: CGFloat,
        cellWidth: CGFloat
    ) -> Int {
        guard cellWidth > 0 else { return 1 }
        switch node.content {
        case .pane:
            return max(1, Int(availableWidth / cellWidth))
        case let .vertical(children):
            return children.map {
                maxColumns(for: $0, availableWidth: availableWidth, cellWidth: cellWidth)
            }.min() ?? 1
        case let .horizontal(children):
            let usable = availableWidth - dividerThickness * CGFloat(max(0, children.count - 1))
            let totalCells = CGFloat(max(1, children.reduce(0) { $0 + $1.width }))
            let childCols = children.reduce(0) { sum, child in
                sum + maxColumns(
                    for: child,
                    availableWidth: usable * CGFloat(child.width) / totalCells,
                    cellWidth: cellWidth
                )
            }
            return childCols + max(0, children.count - 1)
        }
    }

    /// Exact pixel height `node` needs to render its tmux-allocated cells plus
    /// chrome (header per pane, divider per vertical gap).
    nonisolated static func pixelNeedHeight(
        of node: RemoteTmuxLayoutNode,
        cell: CGSize,
        headerHeight: CGFloat = RemoteTmuxPaneHeader.height
    ) -> CGFloat {
        switch node.content {
        case .pane:
            return CGFloat(node.height) * cell.height + headerHeight
        case let .horizontal(children):
            return children.map { pixelNeedHeight(of: $0, cell: cell, headerHeight: headerHeight) }.max() ?? 0
        case let .vertical(children):
            let dividers = dividerThickness * CGFloat(max(0, children.count - 1))
            return children.reduce(0) { $0 + pixelNeedHeight(of: $1, cell: cell, headerHeight: headerHeight) } + dividers
        }
    }

    /// Exact pixel width `node` needs (divider per horizontal gap; headers add
    /// no width).
    nonisolated static func pixelNeedWidth(of node: RemoteTmuxLayoutNode, cell: CGSize) -> CGFloat {
        switch node.content {
        case .pane:
            return CGFloat(node.width) * cell.width
        case let .vertical(children):
            return children.map { pixelNeedWidth(of: $0, cell: cell) }.max() ?? 0
        case let .horizontal(children):
            let dividers = dividerThickness * CGFloat(max(0, children.count - 1))
            return children.reduce(0) { $0 + pixelNeedWidth(of: $1, cell: cell) } + dividers
        }
    }

    /// Splits `usable` pixels among `children` along `axis` so every child gets
    /// AT LEAST the pixels its tmux cell allocation needs, distributing any
    /// slack proportionally to the tmux extents (and degrading to
    /// need-proportional shrink when the area is genuinely too small). Falls
    /// back to raw extent proportion when no cell size is known yet.
    nonisolated static func childPixelSpans(
        children: [RemoteTmuxLayoutNode],
        horizontalAxis: Bool,
        usable: CGFloat,
        cell: CGSize?,
        headerHeight: CGFloat = RemoteTmuxPaneHeader.height
    ) -> [CGFloat] {
        let weights = children.map { CGFloat(horizontalAxis ? $0.width : $0.height) }
        let totalWeight = max(1, weights.reduce(0, +))
        guard let cell else {
            return weights.map { usable * $0 / totalWeight }
        }
        let needs = children.map { child in
            horizontalAxis
                ? pixelNeedWidth(of: child, cell: cell)
                : pixelNeedHeight(of: child, cell: cell, headerHeight: headerHeight)
        }
        let totalNeed = needs.reduce(0, +)
        guard totalNeed > 0 else {
            return weights.map { usable * $0 / totalWeight }
        }
        let slack = usable - totalNeed
        guard slack >= 0 else {
            return needs.map { usable * $0 / totalNeed }
        }
        return zip(needs, weights).map { need, weight in need + slack * weight / totalWeight }
    }
}
