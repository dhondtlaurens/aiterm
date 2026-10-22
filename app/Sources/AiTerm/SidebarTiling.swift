import AppKit
import AiTermUI
import AiTermCore

/// The sidebar window and the terminal windows tiled beside it. Wherever the sidebar goes — dragged,
/// resized, onto another screen, or redrawn at another size — its frame is saved and every task's,
/// terminal's and operator's window is re-framed to fill the rest of the screen.
@MainActor
final class SidebarTiling {
    /// Set once the app has made the window.
    weak var sidebarWindow: NSWindow?
    private let preferences: InterfacePreferences
    /// Where the sidebar's frame is saved and the windows to tile are listed, and the connection
    /// that moves them.
    private let workspace: WorkspaceStore
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// Trailing debounce for `sidebarMoved()`: `didMoveNotification` fires for every pixel of a
    /// drag, and each one would otherwise write state.json and re-frame every iTerm2 window.
    private var pendingMove: Task<Void, Never>?
    private let moveDelay: TimeInterval
    /// The re-tiling under way. A newer one, for a newer frame, cancels it: two running at once
    /// would leave each window wherever the later reply put it.
    private var snapTask: Task<Void, Never>?
    /// The sidebar's frame as a sheet began, held until it ends. AppKit slides the sidebar aside to
    /// fit a sheet wider than it — the 560-point ones beside a 360-point sidebar at the screen's
    /// edge — and back once it closes; New Terminal opens its window while its sheet is closing.
    private var frameBeforeSheet: CGRect?

    init(preferences: InterfacePreferences, moveDelay: TimeInterval = 0.15, workspace: WorkspaceStore,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?) {
        self.moveDelay = moveDelay
        self.preferences = preferences
        self.workspace = workspace
        self.daemon = daemon
    }

    private static let defaultSidebarRect = CGRect(x: 0, y: 0, width: 300, height: 800)
    /// Used when AppKit reports no screen at all (a detached or headless session): better a plain
    /// frame the daemon can still apply than a crash.
    private static let defaultTaskFrame = Frame(x: 312, y: 0, w: 1128, h: 800)

    /// Where a task's or terminal's window goes: beside the sidebar, on its screen — where it rests,
    /// not where a sheet has pushed it.
    func taskFrame() -> Frame {
        let sidebar = frameBeforeSheet ?? sidebarWindow?.frame ?? Self.defaultSidebarRect
        guard let screen = sidebarWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return Self.defaultTaskFrame }
        return Frame(Snap.taskFrame(sidebar: sidebar, screenVisible: screen.visibleFrame))
    }

    /// Draws the sidebar at `size`, keeping its window in proportion to its content, then re-tiles
    /// the terminal windows beside it. Settings' Save and the View menu both come here. The
    /// re-tiling, if any window was moved.
    @discardableResult
    func setInterfaceSize(_ size: InterfaceSize) -> Task<Void, Never>? {
        guard size != preferences.interfaceSize else { return nil }
        let old = preferences.interfaceSize.scale
        preferences.interfaceSize = size
        guard let window = sidebarWindow else { return nil }
        let scale = size.scale
        let limit = (window.screen?.visibleFrame.maxX ?? .greatestFiniteMagnitude) - window.frame.minX
        var frame = window.frame
        frame.size.width = Self.sidebarWidth(frame.width, from: old, to: scale, limit: limit)
        // Before the frame: a minimum above the current width would otherwise hold the old one.
        window.minSize = NSSize(width: scale(Size.sidebarMinWidth), height: window.minSize.height)
        window.setFrame(frame, display: true)
        // Settings' Save runs under its sheet: the frame the sidebar returns to takes the new width.
        frameBeforeSheet?.size.width = frame.width
        return sidebarFrameChanged()
    }

    /// The sidebar's width after a size change: in proportion to its content, no wider than
    /// `limit` (the screen's edge), and never below the new minimum, which wins over the edge.
    static func sidebarWidth(_ width: CGFloat, from old: InterfaceScale, to new: InterfaceScale,
                             limit: CGFloat) -> CGFloat {
        max(new(Size.sidebarMinWidth), min(limit, (width * new.factor / old.factor).rounded()))
    }

    /// The sidebar moved, was resized or its screen changed; acted on once it has settled.
    func sidebarMoved() {
        pendingMove?.cancel()
        pendingMove = Task { [weak self, moveDelay] in
            try? await Task.sleep(for: .seconds(moveDelay))
            // Cancelled while asleep, or once awake but before this turn: a later move, or
            // `finishPendingMove()`, has taken over.
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// Quit acts on a move still waiting out its debounce, so the frame it ended on is saved.
    func finishPendingMove() {
        guard let pendingMove else { return }
        pendingMove.cancel()
        settle()
    }

    /// A sheet is about to open: before AppKit moves the sidebar to make room for it.
    func sheetWillBegin() {
        if frameBeforeSheet == nil { frameBeforeSheet = sidebarWindow?.frame }
    }

    /// The sheet is gone and the sidebar back where it rests, or wherever it was dragged meanwhile.
    func sheetDidEnd() {
        frameBeforeSheet = nil
        sidebarMoved()
    }

    private func settle() {
        pendingMove = nil
        // The sheet's slide is not saved nor tiled to: `sheetDidEnd()` settles the sidebar after it.
        guard frameBeforeSheet == nil else { return }
        sidebarFrameChanged()
    }

    @discardableResult
    private func sidebarFrameChanged() -> Task<Void, Never>? {
        guard let window = sidebarWindow else { return nil }
        let frame = frameBeforeSheet ?? window.frame
        workspace.mutate { $0.sidebarFrame = frame }
        return snapAll()
    }

    /// Puts every open task, terminal and operator window beside the sidebar.
    private func snapAll() -> Task<Void, Never>? {
        guard let daemon = daemon() else { return nil }
        let state = workspace.state
        let frame = taskFrame()
        let ids = state.tasks.compactMap(\.windowId) + state.terminals.compactMap(\.windowId)
            + state.runs.compactMap(\.operatorWindowId)
        snapTask?.cancel()
        let task = Task {
            for id in ids {
                guard !Task.isCancelled else { return }
                try? await daemon.setFrame(windowId: id, frame: frame)
            }
        }
        snapTask = task
        return task
    }
}
