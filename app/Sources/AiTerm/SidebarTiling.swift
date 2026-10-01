import AppKit
import AiTermUI
import AiTermCore

/// The sidebar window and the terminal windows tiled beside it. Wherever the sidebar goes — dragged,
/// resized, onto another screen, or redrawn at another size — its frame is saved and every task's
/// and terminal's window is re-framed to fill the rest of the screen.
@MainActor
final class SidebarTiling {
    /// Set once the app has made the window.
    weak var sidebarWindow: NSWindow?
    private let preferences: InterfacePreferences
    /// The windows to tile, the daemon that moves them and where the sidebar's frame is saved: the
    /// workspace's and the connection's.
    private let tiledWindows: @MainActor () -> [String]
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let saveSidebarFrame: @MainActor (CGRect) -> Void
    /// Trailing debounce for `sidebarMoved()`: `didMoveNotification` fires for every pixel of a
    /// drag, and each one would otherwise write state.json and re-frame every iTerm2 window.
    private var pendingMove: DispatchWorkItem?
    private let moveDelay = 0.15

    init(preferences: InterfacePreferences, tiledWindows: @escaping @MainActor () -> [String],
         daemon: @escaping @MainActor () -> (any DaemonCommands)?, saveSidebarFrame: @escaping @MainActor (CGRect) -> Void) {
        self.preferences = preferences
        self.tiledWindows = tiledWindows
        self.daemon = daemon
        self.saveSidebarFrame = saveSidebarFrame
    }

    private static let defaultSidebarRect = CGRect(x: 0, y: 0, width: 300, height: 800)
    /// Used when AppKit reports no screen at all (a detached or headless session): better a plain
    /// frame the daemon can still apply than a crash.
    private static let defaultTaskFrame = Frame(x: 312, y: 0, w: 1128, h: 800)

    /// Where a task's or terminal's window goes: beside the sidebar, on its screen.
    func taskFrame() -> Frame {
        let sidebar = sidebarWindow?.frame ?? Self.defaultSidebarRect
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
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle() } }
        pendingMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + moveDelay, execute: work)
    }

    /// Quit acts on a move still waiting out its debounce, so the frame it ended on is saved.
    func finishPendingMove() {
        guard let pendingMove else { return }
        pendingMove.cancel()
        settle()
    }

    private func settle() {
        pendingMove = nil
        sidebarFrameChanged()
    }

    @discardableResult
    private func sidebarFrameChanged() -> Task<Void, Never>? {
        guard let window = sidebarWindow else { return nil }
        saveSidebarFrame(window.frame)
        return snapAll()
    }

    private func snapAll() -> Task<Void, Never>? {
        guard let daemon = daemon() else { return nil }
        let frame = taskFrame(), ids = tiledWindows()
        return Task { for id in ids { try? await daemon.setFrame(windowId: id, frame: frame) } }
    }
}
