import AppKit
import Testing
@testable import AiTerm
@testable import AiTermTestSupport

/// ↩ on a list sheet's highlighted row opens the row's gear menu as a click does, with its first enabled item
/// highlighted; the menu is the row's context menu, `RowCommandMenu`, hung below the gear.
@Suite @MainActor struct RowMenuTests {
    private let commands: [[RowCommand]] = [
        [RowCommand(title: "Edit Signal…", enabled: false) {}, RowCommand(title: "Switch Off") {}],
        [RowCommand(title: "Remove Signal…", role: .destructive) {}],
    ]

    @Test func returnAsksTheHighlightedRowAndAgainOnEachPress() throws {
        let row = UUID(), other = UUID()
        let first = try #require(ListMenuRequest.after(nil, highlighted: row, commands: commands))
        #expect(first.id == row, "only the highlighted row hears it")
        let second = try #require(ListMenuRequest.after(first, highlighted: row, commands: commands))
        #expect(second.id == row && second != first, "a second ↩ on the same row opens it again")
        let moved = try #require(ListMenuRequest.after(second, highlighted: other, commands: commands))
        #expect(moved.id == other)
    }

    /// The search field's commands reach the sheet's own unless they are ↩ with a row to open.
    @Test func onlyAPlainReturnFromTheSearchFieldOpensAMenu() {
        let row = UUID()
        #expect(ListMenuRequest.on(#selector(NSResponder.insertNewline(_:)), after: nil, highlighted: row, commands: commands)?.id == row)
        for other in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.cancelOperation(_:)),
                      #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))] {
            #expect(ListMenuRequest.on(other, after: nil, highlighted: row, commands: commands) == nil, "\(other)")
        }
        #expect(ListMenuRequest.on(#selector(NSResponder.insertNewline(_:)), after: nil, highlighted: nil, commands: commands) == nil)
    }

    @Test func returnIsTheFieldsWithNoRowOrNothingToChoose() {
        #expect(ListMenuRequest.after(nil, highlighted: nil, commands: commands) == nil, "nothing highlighted")
        let greyed = [[RowCommand(title: "Edit Signal…", enabled: false) {}]]
        #expect(ListMenuRequest.after(nil, highlighted: UUID(), commands: greyed) == nil, "every command greyed")
        #expect(ListMenuRequest.after(nil, highlighted: UUID(), commands: []) == nil)
    }

    /// The presenter with its menu recorded instead of shown, and its turn taken at once.
    private final class Recorder {
        var posted: [NSEvent] = []
        var shown: [(titles: [String], point: NSPoint, view: NSView, postedBefore: Int)] = []
    }

    private func presenter(anchoredIn window: NSWindow?) -> (RowMenuPresenter, Recorder, NSView) {
        let presenter = RowMenuPresenter(), recorder = Recorder()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        window?.contentView?.addSubview(anchor)
        presenter.anchor = anchor
        presenter.later = { $0() }
        presenter.post = { recorder.posted.append($0) }
        presenter.popUp = { menu, point, view in
            recorder.shown.append((menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, point, view, recorder.posted.count))
        }
        return (presenter, recorder, anchor)
    }

    @Test func theKeyboardOpensTheRowsMenuBelowTheGearWithItsFirstItemHighlighted() throws {
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (presenter, recorder, anchor) = presenter(anchoredIn: window)
        presenter.open(commands, from: .keyboard)
        let shown = try #require(recorder.shown.first)
        #expect(shown.titles == ["Edit Signal…", "Switch Off", "—", "Remove Signal…"], "the row's context menu, greyed item and all")
        #expect(shown.view === anchor && shown.point == NSPoint(x: 0, y: anchor.bounds.height))
        // A ↓ queued ahead of the menu: AppKit highlights the first enabled item, past the greyed Edit Signal….
        let down = try #require(recorder.posted.first)
        #expect(shown.postedBefore == 1)
        #expect(down.type == .keyDown && down.keyCode == 125 && down.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty)
        #expect(down.windowNumber == window.windowNumber)
    }

    @Test func aClickOpensTheSameMenuWithNothingHighlighted() throws {
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (presenter, recorder, _) = presenter(anchoredIn: window)
        presenter.open(commands, from: .click)
        #expect(recorder.shown.first?.titles == ["Edit Signal…", "Switch Off", "—", "Remove Signal…"])
        #expect(recorder.posted.isEmpty)
    }

    @Test func aGearOutOfItsWindowOpensNothingAndQueuesNoArrow() {
        let (presenter, recorder, _) = presenter(anchoredIn: nil)
        presenter.open(commands, from: .keyboard)
        #expect(recorder.shown.isEmpty && recorder.posted.isEmpty, "a stray ↓ would move the sheet's highlight")
    }

    @Test func theMenuWaitsATurnAfterTheKey() {
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (presenter, recorder, _) = presenter(anchoredIn: window)
        var pending: [@MainActor () -> Void] = []
        presenter.later = { pending.append($0) }
        presenter.open(commands, from: .keyboard)
        #expect(recorder.shown.isEmpty && recorder.posted.isEmpty, "never inside the key handler")
        pending.forEach { $0() }
        #expect(recorder.shown.count == 1)
    }
}
