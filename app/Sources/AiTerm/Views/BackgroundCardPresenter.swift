import AppKit
import Observation
import SwiftUI
import AiTermCore
import AiTermUI

/// One native floating card per sidebar: a trailing mark's background-work card or a signals disc's signal card,
/// one at a time, so presenting one closes the other. Source identity and geometry live here; the jobs and the signal
/// card remain in the existing projection. A child window isolates the List's independent tracking/tooltips.
@MainActor final class BackgroundCardPresenter {
    /// Which card a source's anchor opens: the trailing mark's jobs, or the avatar disc's signal card.
    enum Kind: Equatable { case jobs, signal }
    private(set) var panel: BackgroundCardPanel?
    private weak var controller: AppController?
    private weak var viewport: NSView?
    private weak var anchor: NSView?
    private var source: RowSelection?
    private(set) var kind = Kind.jobs
    private var hover: BackgroundCardHover?
    private var observation = 0

    static func eligible(_ jobs: [BackgroundJob], source: RowSelection, controller: AppController) -> [BackgroundJob] {
        if leaving(source, controller: controller) { return [] }
        return jobs
    }

    /// A row on its way out offers no card.
    static func leaving(_ source: RowSelection, controller: AppController) -> Bool {
        if case .task(let id) = source { return controller.teardown.state(of: id)?.inProgress == true }
        return false
    }

    /// The open background-work card; nil while a signal card is open.
    var card: BackgroundCard? {
        guard kind == .jobs, let source, let controller, let jobs = controller.rows.backgroundJobs(for: source) else { return nil }
        let eligible = Self.eligible(jobs, source: source, controller: controller)
        return eligible.isEmpty ? nil : BackgroundCard(jobs: eligible)
    }

    /// The open signal card, as the projection has it now; nil while a background-work card is open.
    var signalCard: SignalCard? {
        guard kind == .signal, let source, let controller, !Self.leaving(source, controller: controller) else { return nil }
        return controller.rows.signalCard(for: source)
    }

    func connect(viewport: NSView, controller: AppController) {
        self.viewport = viewport; self.controller = controller
        refresh()
    }

    func present(source: RowSelection, anchor: NSView, hover: BackgroundCardHover, kind: Kind = .jobs) {
        guard self.source != source || self.anchor !== anchor || self.hover !== hover || self.kind != kind else { refresh(); return }
        close()
        self.source = source; self.anchor = anchor; self.hover = hover; self.kind = kind
        observeSource()
    }

    func dismiss(anchor: NSView) {
        if self.anchor === anchor { close() }
    }

    func close() {
        observation += 1
        let oldHover = hover
        hover = nil; source = nil; anchor = nil; kind = .jobs
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

    /// Where the open card goes, in screen points, and what it draws, or nil when its source can show none: its source
    /// mark out of the viewport, no room, nothing to say.
    private func placement(row: NSRect, available: NSRect, scale: InterfaceScale) -> (frame: NSRect, content: AnyView)? {
        guard available.height > 0 else { return nil }
        // The same vertical rule for both: the card's top on the pill's, moved up to stay inside the viewport.
        func top(_ height: CGFloat) -> CGFloat {
            max(available.minY, min(row.maxY + scale(Space.base) - height, available.maxY - height))
        }
        switch kind {
        case .jobs:
            guard let card else { return nil }
            let mark = NSPoint(x: row.maxX - SidebarRowLayout.trailingSlot(scale) / 2, y: row.midY)
            guard available.contains(mark) else { return nil }
            let width = min(available.width, row.width + scale(Space.base)
                            - SidebarRowLayout.trailingSlot(scale) - scale(Space.tight))
            guard width > 0 else { return nil }
            let visibleJobs = BackgroundCardView.visibleJobs(total: card.jobs.count, availableHeight: available.height, scale: scale)
            guard visibleJobs > 0 else { return nil }
            let height = BackgroundCardView.height(jobs: visibleJobs, scale: scale)
            let frame = NSRect(x: max(available.minX, min(row.minX - scale(Space.base), available.maxX - width)),
                               y: top(height), width: width, height: height)
            return (frame, AnyView(BackgroundCardView(card: card, visibleJobs: visibleJobs)))
        case .signal:
            guard let card = signalCard else { return nil }
            // The disc, on the avatar column's first mark, has to be in view; the card starts after the column, so it
            // stays so, and reaches the pill's trailing edge.
            let disc = AvatarGroupView.discCentre(scale)
            guard available.contains(NSPoint(x: row.minX + disc, y: row.midY)) else { return nil }
            let leading = Self.signalCardLeading(row: row, scale: scale)
            let width = min(available.maxX, row.maxX + SidebarRowLayout.trailingInset(scale)) - leading
            guard width > 0 else { return nil }
            let steps = SignalCardView.visibleSteps(total: card.steps.count, availableHeight: available.height, scale: scale)
            guard SignalCardView.height(lines: 1, scale: scale) <= available.height else { return nil }
            let height = SignalCardView.height(lines: steps + 1, scale: scale)
            return (NSRect(x: leading, y: top(height), width: width, height: height),
                    AnyView(SignalCardView(card: card, visibleSteps: steps)))
        }
    }

    /// The signal card's leading edge, "after the avatar": the avatar column's trailing edge plus `Space.tight`, from
    /// the row content's leading edge (`row`, inside SelectableRow's padding).
    static func signalCardLeading(row: NSRect, scale: InterfaceScale) -> CGFloat {
        row.minX + AvatarGroupView.columnWidth(scale) + scale(Space.tight)
    }

    func refresh() {
        guard source != nil else { return }
        guard hover?.isOpen == true, let controller, let viewport, let anchor, let window = viewport.window,
              anchor.window === window, !viewport.isHiddenOrHasHiddenAncestor,
              !anchor.isHiddenOrHasHiddenAncestor, window.isVisible, !window.isMiniaturized else { close(); return }
        let scale = controller.preferences.interfaceSize.scale
        let available = window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard let (frame, card) = placement(row: row, available: available, scale: scale) else { close(); return }
        let content = AnyView(card
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
    var kind = BackgroundCardPresenter.Kind.jobs

    final class Probe: NSView {
        var source: RowSelection = .operatorChat
        private(set) var kind = BackgroundCardPresenter.Kind.jobs
        private(set) weak var presenter: BackgroundCardPresenter?
        private(set) var hover: BackgroundCardHover?
        var activate: () -> Void = {}
        var commands: [[RowCommand]] = []
        private var observation = 0

        func configure(source: RowSelection, presenter: BackgroundCardPresenter, hover: BackgroundCardHover,
                       activate: @escaping () -> Void, commands: [[RowCommand]], kind: BackgroundCardPresenter.Kind = .jobs) {
            self.activate = activate; self.commands = commands
            defer { if hover.isOpen { presenter.refresh() } }
            guard self.source != source || self.presenter !== presenter || self.hover !== hover || self.kind != kind else { return }
            self.presenter?.dismiss(anchor: self)
            self.source = source; self.presenter = presenter; self.hover = hover; self.kind = kind
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
            if opened, window != nil { presenter?.present(source: source, anchor: self, hover: hover, kind: kind) }
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
        view.configure(source: source, presenter: presenter, hover: hover, activate: activate, commands: commands, kind: kind)
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
