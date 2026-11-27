import SwiftUI
import AppKit
import AiTermUI

/// The gear of a list sheet's row, drawn as `AddMenu` draws the headings' +: `gearshape` in `Typography.label`, the
/// surface's secondary ink, no ground, a `trailingSlot` square. Its menu is AppKit's, popped from code, so ↩ opens it as
/// a click does; a SwiftUI `Menu` cannot be opened from code. Either way the menu is `RowCommandMenu`, the row's context
/// menu, hosted in an `NSHostingMenu`, so the two cannot drift.
struct RowMenuButton: View {
    let help: String
    let commands: [[RowCommand]]
    /// ↩'s pending request for this row: the menu opens from the keyboard as soon as the gear is there, on a new request
    /// or on the gear's appearing with one, and says it is served. Nil on every other row.
    var opening: RowMenuOpening?
    @State private var presenter = RowMenuPresenter()
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface
    /// `ImageRenderer` cannot draw an AppKit view, and a snapshot opens no menu: it draws the gear without its anchor.
    #if DEBUG
    @Environment(\.snapshotRendering) private var isSnapshot
    #else
    private let isSnapshot = false
    #endif

    var body: some View {
        let slot = SidebarRowLayout.trailingSlot(scale)
        Button { presenter.open(commands, from: .click) } label: {
            Image(systemName: "gearshape").font(Typography.label).foregroundStyle(surface.secondaryInk)
                .frame(width: slot, height: slot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!RowCommand.anyEnabled(in: commands))
        .background { if !isSnapshot { RowMenuAnchor(presenter: presenter) } }
        .help(help)
        .task(id: opening?.count) {
            guard let opening else { return }
            opening.served()
            if RowCommand.anyEnabled(in: commands) { presenter.open(commands, from: .keyboard) }
        }
    }
}

/// Pops a row's menu below its gear, a run-loop turn after the click or the key: `popUp` tracks modally and runs the
/// chosen item before it returns, and an item such as Remove… asks an `NSAlert`, which must not run inside a key
/// handler or a SwiftUI update. Opened from the keyboard, the menu gets a ↓ queued ahead of it, so it opens with its
/// first enabled item highlighted, as a menu opened from the keyboard does; AppKit skips the greyed ones. A click opens
/// it with nothing highlighted.
@MainActor
final class RowMenuPresenter {
    enum Opening { case click, keyboard }

    /// The gear's AppKit stand-in, which the menu hangs from.
    weak var anchor: NSView?
    /// Seams the tests replace: the turn the menu waits for, queueing the ↓, and showing the menu.
    var later: (@escaping @MainActor () -> Void) -> Void = { work in
        RunLoop.main.perform { MainActor.assumeIsolated(work) }
    }
    var post: (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) }
    var popUp: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in menu.popUp(positioning: nil, at: point, in: view) }

    func open(_ commands: [[RowCommand]], from opening: Opening) {
        later { [weak self] in self?.show(commands, opening) }
    }

    private func show(_ commands: [[RowCommand]], _ opening: Opening) {
        // A row scrolled out of a lazy list has no window: nothing to hang a menu from.
        guard let anchor, let window = anchor.window else { return }
        let menu = NSHostingMenu(rootView: RowCommandMenu(groups: commands))
        if opening == .keyboard, let down = Self.downArrow(in: window) { post(down) }
        // The anchor is flipped: the menu's top-left corner sits at the gear's bottom-left, as a pull-down's does.
        popUp(menu, NSPoint(x: 0, y: anchor.bounds.height), anchor)
    }

    /// A plain ↓, for the window the menu opens over.
    static func downArrow(in window: NSWindow) -> NSEvent? {
        let arrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: arrow,
                                charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 125)
    }
}

/// The gear's frame as an AppKit view, flipped so the menu's point is measured from its top. It takes no clicks: the
/// gear's `Button` keeps them.
private struct RowMenuAnchor: NSViewRepresentable {
    let presenter: RowMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { presenter.anchor = view }

    private final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// ↩ asking the highlighted row of a list sheet to open its menu: the row's id, and a count that grows with each ↩, so
/// a second ↩ on the same row opens it again.
struct ListMenuRequest: Equatable {
    var id: UUID
    var count: Int

    /// The search field's command as a list sheet hears it first: ↩ makes a request (`after`); any other command, or ↩
    /// with nothing to open, is nil and goes on to the sheet's own commands.
    static func on(_ selector: Selector, after previous: Self?, highlighted id: UUID?, commands: [[RowCommand]]) -> Self? {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return nil }
        return after(previous, highlighted: id, commands: commands)
    }

    /// The request ↩ makes after `previous`: none without a highlighted row, or when every command on it is greyed, and
    /// ↩ is then the field's own.
    static func after(_ previous: Self?, highlighted id: UUID?, commands: [[RowCommand]]) -> Self? {
        guard let id, RowCommand.anyEnabled(in: commands) else { return nil }
        return Self(id: id, count: (previous?.count ?? 0) + 1)
    }
}

/// A pending `ListMenuRequest` as its row hears it: its count, and `served`, which the gear calls as it opens the menu so a
/// row that leaves the list and comes back does not open it again. Equal by count.
struct RowMenuOpening: Equatable {
    let count: Int
    let served: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
}
