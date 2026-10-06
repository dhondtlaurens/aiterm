import AppKit
import SwiftUI
import AiTermUI
import AiTermCore
import Testing
@testable import AiTerm
@testable import AiTermTestSupport

/// The sheet edits the list of Jira projects linked to a project. It picks from every Jira project
/// the account can see — hundreds of them — so it searches rather than scrolls. These tests drive
/// the rendered field the way the ticket picker's do.
@MainActor
@Suite(.serialized) struct JiraProjectSheetTests {
    static let site = URL(string: "https://example.atlassian.net")!
    static let projects = [
        JiraProjectRef(id: "1", key: "PLT", name: "Platform", siteURL: site),
        JiraProjectRef(id: "2", key: "WEB", name: "Website", siteURL: site),
        JiraProjectRef(id: "3", key: "WEBX", name: "Website extras", siteURL: site),
    ]
    static let placeholder = "Add a Jira project by key or name"

    /// What `submit` was handed, and whether it was called at all — an empty list is a real answer,
    /// so the count matters as much as the value.
    final class Submissions {
        var calls: [[JiraProjectRef]] = []
    }

    struct Harness {
        let host: NSHostingView<JiraProjectSheet>
        let window: NSWindow
        let submissions: Submissions
    }

    /// `loadProjects` runs from `.task`, which a bare `NSHostingView` never gets to — the sheet is
    /// presented, not hosted, in the app. `seedProjects` writes the same `State` that load writes,
    /// so these tests exercise the picker rather than SwiftUI's appearance plumbing.
    private func harness(linked: [JiraProjectRef] = [], listOpen: Bool = false, seedProjects: Bool = false) -> Harness {
        let submissions = Submissions()
        // The chevron opens the list in the app; seeding it is the same `State` the button writes,
        // as `NewReviewSheetTests` does for the branch picker.
        let sheet = JiraProjectSheet(projectName: "aiterm", linked: linked, canSubmit: true,
                                     loadProjects: { Self.projects },
                                     submit: { submissions.calls.append($0) })
            .seeded(projects: seedProjects ? Self.projects : nil, open: listOpen)
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host)
        return Harness(host: host, window: window, submissions: submissions)
    }

    private func field(in host: NSView) -> NSTextField? {
        descendants(of: NSTextField.self, in: host).first { $0.placeholderString == Self.placeholder }
    }

    private func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func send(_ selector: Selector, to field: NSTextField) -> Bool {
        field.delegate?.control?(field, textView: NSTextView(), doCommandBy: selector) ?? false
    }

    private func pressCommandReturn(_ h: Harness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host, for: 0.1)
    }

    @Test func testTypingNarrowsTheListSoReturnAddsTheMatchingProject() throws {
        let h = harness(listOpen: true, seedProjects: true)
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(in: h.host))

        // "webx" matches one of the three projects; ⏎ takes the row the narrowed list highlights.
        type("webx", into: field)
        settle(h.host)
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        settle(h.host)

        // A pick joins the list above the field, and the field stays for the next one.
        #expect(self.field(in: h.host) != nil)
        pressCommandReturn(h)
        #expect(h.submissions.calls == [[Self.projects[2]]])
    }

    /// A project picked here joins the ones already linked, after them.
    @Test func testAPickIsAddedAfterTheLinkedProjects() throws {
        let h = harness(linked: [Self.projects[0]], listOpen: true, seedProjects: true)
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(in: h.host))

        type("web", into: field)
        settle(h.host)
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        settle(h.host)
        pressCommandReturn(h)

        #expect(h.submissions.calls == [[Self.projects[0], Self.projects[1]]])
    }

    @Test func testSavingWithoutAPickKeepsTheLinkedProjects() throws {
        let h = harness(linked: [Self.projects[1], Self.projects[0]], seedProjects: true)
        defer { h.window.orderOut(nil) }

        pressCommandReturn(h)

        #expect(h.submissions.calls == [[Self.projects[1], Self.projects[0]]])
    }

    /// Nothing linked is a valid answer: New Task then searches every Jira project. The sheet does
    /// not preselect one — a project chosen by alphabet is not one the reader picked.
    @Test func testAnEmptyListMeansNoJiraProject() throws {
        let h = harness(seedProjects: true)
        defer { h.window.orderOut(nil) }
        #expect(self.field(in: h.host) != nil)

        pressCommandReturn(h)

        #expect(h.submissions.calls == [[]])
    }

    /// ⎋ with the list open closes the list, not the sheet: an unlink made before it survives, and
    /// Save still hands it up. The list's own ⎋ had lost to Cancel's key equivalent.
    @Test func escapeClosesTheListBeforeTheSheet() throws {
        let h = harness(linked: [Self.projects[0], Self.projects[1]], listOpen: true, seedProjects: true)
        defer { h.window.orderOut(nil) }
        #expect(listIsOpen(in: h.host))

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        _ = h.window.performKeyEquivalent(with: escape)
        settle(h.host)

        #expect(!listIsOpen(in: h.host))
        #expect(self.field(in: h.host) != nil, "the sheet is still up")
        pressCommandReturn(h)
        #expect(h.submissions.calls == [[Self.projects[0], Self.projects[1]]])
    }

    /// Whether the list is open, asked as the rendered sheet answers it: an open list with rows
    /// takes ↓, a closed one hands it back.
    private func listIsOpen(in host: NSView) -> Bool {
        guard let field = field(in: host) else { return false }
        return send(#selector(NSResponder.moveDown(_:)), to: field)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews { matches += descendants(of: type, in: subview) }
        return matches
    }
}
