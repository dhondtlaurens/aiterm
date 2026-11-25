import AppKit
import Observation
import SwiftUI
import AiTermCore
import AiTermUI

/// One native floating card per sidebar. Source identity and geometry live here; the jobs remain
/// in the existing projection. A child window isolates the List's independent tracking/tooltips.
@MainActor final class BackgroundCardPresenter {
    private(set) var panel: BackgroundCardPanel?
    private weak var controller: AppController?
    private weak var viewport: NSView?
    private weak var anchor: NSView?
    private var source: RowSelection?
    private var hover: BackgroundCardHover?
    private var observation = 0

    static func eligible(_ jobs: [BackgroundJob], source: RowSelection, controller: AppController) -> [BackgroundJob] {
        if case .task(let id) = source, controller.teardown.state(of: id)?.inProgress == true { return [] }
        return jobs
    }

    var card: BackgroundCard? {
        guard let source, let controller, let jobs = controller.rows.backgroundJobs(for: source) else { return nil }
        let eligible = Self.eligible(jobs, source: source, controller: controller)
        return eligible.isEmpty ? nil : BackgroundCard(jobs: eligible)
    }

    func connect(viewport: NSView, controller: AppController) {
        self.viewport = viewport; self.controller = controller
        refresh()
    }

    func present(source: RowSelection, anchor: NSView, hover: BackgroundCardHover) {
        guard self.source != source || self.anchor !== anchor || self.hover !== hover else { refresh(); return }
        close()
        self.source = source; self.anchor = anchor; self.hover = hover
        observeSource()
    }

    func dismiss(anchor: NSView) {
        if self.anchor === anchor { close() }
    }

    func close() {
        observation += 1
        let oldHover = hover
        hover = nil; source = nil; anchor = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        oldHover?.close()
    }

    private func observeSource() {
        observation += 1
        let version = observation
        withObservationTracking { refresh() } onChange: { [weak self] in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    guard let self, self.observation == version else { return }
                    self.observeSource()
                }
            }
        }
    }

    func refresh() {
        guard source != nil else { return }
        guard hover?.isOpen == true, let card, let controller, let viewport, let anchor, let window = viewport.window,
              anchor.window === window, !viewport.isHiddenOrHasHiddenAncestor,
              !anchor.isHiddenOrHasHiddenAncestor, window.isVisible, !window.isMiniaturized else { close(); return }
        let scale = controller.preferences.interfaceSize.scale
        let available = window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let mark = NSPoint(x: row.maxX - SidebarRowLayout.trailingSlot(scale) / 2, y: row.midY)
        guard available.contains(mark), available.height > 0 else { close(); return }
        let width = min(available.width, row.width + scale(Space.base)
                        - SidebarRowLayout.trailingSlot(scale) - scale(Space.tight))
        guard width > 0 else { close(); return }
        let visibleJobs = BackgroundCardView.visibleJobs(total: card.lines.count, availableHeight: available.height, scale: scale)
        guard visibleJobs > 0 else { close(); return }
        let height = BackgroundCardView.height(jobs: visibleJobs, scale: scale)
        let frame = NSRect(x: max(available.minX, min(row.minX - scale(Space.base), available.maxX - width)),
                           y: max(available.minY, min(row.maxY + scale(Space.base) - height, available.maxY - height)),
                           width: width, height: height)
        let content = AnyView(BackgroundCardView(card: card, visibleJobs: visibleJobs)
            .onTapGesture { [weak anchor] in (anchor as? BackgroundCardAnchor.Probe)?.activate() }
            .allowsWindowActivationEvents()
            .modifier(RowCommandContextMenu(groups: (anchor as? BackgroundCardAnchor.Probe)?.commands ?? []))
            .interfaceScale(scale).preferredColorScheme(.dark))
        if let panel, let host = panel.contentView as? BackgroundCardHostingView {
            host.rootView = content
            panel.setFrame(frame, display: true)
        } else {
            let host = BackgroundCardHostingView(rootView: content)
            host.safeAreaRegions = []; host.sizingOptions = []
            host.hover = { [weak self, weak host] inside in
                guard let self, self.panel?.contentView === host else { return }
                self.hover?.card(inside)
            }
            let panel = BackgroundCardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.isFloatingPanel = false; panel.hidesOnDeactivate = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.level = window.level
            panel.contentView = host
            self.panel = panel
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            // Attaching the hosting view may adjust the initial content size to its backing
            // grid; finish with the same explicit frame used for every later update.
            panel.setFrame(frame, display: true)
        }
    }

    isolated deinit { close() }
}

final class BackgroundCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BackgroundCardHostingView: NSHostingView<AnyView> {
    var hover: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); self.area = area
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
}

private struct BackgroundCardPresenterKey: EnvironmentKey {
    static let defaultValue: BackgroundCardPresenter? = nil
}

extension EnvironmentValues {
    var backgroundCardPresenter: BackgroundCardPresenter? {
        get { self[BackgroundCardPresenterKey.self] }
        set { self[BackgroundCardPresenterKey.self] = newValue }
    }
}

/// The row's bounds cross a native hosting boundary. This transparent, non-hit-testing probe
/// supplies an AppKit anchor without retaining a second list of the row's jobs.
struct BackgroundCardAnchor: NSViewRepresentable {
    let source: RowSelection
    let presenter: BackgroundCardPresenter
    let hover: BackgroundCardHover
    let activate: () -> Void
    let commands: [[RowCommand]]

    final class Probe: NSView {
        var source: RowSelection = .operatorChat
        private(set) weak var presenter: BackgroundCardPresenter?
        private(set) var hover: BackgroundCardHover?
        var activate: () -> Void = {}
        var commands: [[RowCommand]] = []
        private var observation = 0

        func configure(source: RowSelection, presenter: BackgroundCardPresenter, hover: BackgroundCardHover,
                       activate: @escaping () -> Void, commands: [[RowCommand]]) {
            self.activate = activate; self.commands = commands
            defer { if hover.isOpen { presenter.refresh() } }
            guard self.source != source || self.presenter !== presenter || self.hover !== hover else { return }
            self.presenter?.dismiss(anchor: self)
            self.source = source; self.presenter = presenter; self.hover = hover
            observeHover()
        }

        private func observeHover() {
            guard let hover else { return }
            observation += 1
            let version = observation
            let opened = withObservationTracking { hover.isOpen } onChange: { [weak self] in
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        guard let self, self.observation == version else { return }
                        self.observeHover()
                    }
                }
            }
            if opened, window != nil { presenter?.present(source: source, anchor: self, hover: hover) }
            else { presenter?.dismiss(anchor: self) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { presenter?.dismiss(anchor: self) } else { observeHover() }
        }
        override func layout() { super.layout(); presenter?.refresh() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        isolated deinit { presenter?.dismiss(anchor: self) }
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {
        view.configure(source: source, presenter: presenter, hover: hover, activate: activate, commands: commands)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.presenter?.dismiss(anchor: view) }
}

/// The available list viewport, excluding titlebar, banners and footer. It also owns native-list
/// scroll notifications so scrolling the card's own jobs never dismisses the card.
struct BackgroundCardViewport: NSViewRepresentable {
    let presenter: BackgroundCardPresenter
    let controller: AppController

    final class Probe: NSView {
        var presenter: BackgroundCardPresenter?
        weak var controller: AppController?
        private weak var clip: NSClipView?
        private var scrollObserver: (any NSObjectProtocol)?
        private var windowObservers: [any NSObjectProtocol] = []

        func configure() {
            guard let presenter, let controller else { return }
            presenter.connect(viewport: self, controller: controller)
            if clip?.window !== window || clip == nil, let new = NativeRowHighlight.table(near: self)?.enclosingScrollView?.contentView {
                if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
                clip = new
                new.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: new, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // Bounds also change during resize and interface scaling. Follow the
                        // anchor while its mark remains visible; refresh dismisses it otherwise.
                        self?.presenter?.refresh()
                    }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { presenter?.close(); return }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window,
                    queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if closing { self.presenter?.close() }
                        else { self.presenter?.refresh() }
                    }
                })
            }
            configure()
        }

        private func stop() {
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers = []
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil; clip = nil
        }
        override func layout() { super.layout(); configure() }
        override func viewDidHide() { super.viewDidHide(); presenter?.close() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        isolated deinit { stop(); presenter?.close() }
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {
        view.presenter = presenter; view.controller = controller; view.configure()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.presenter?.close() }
}
