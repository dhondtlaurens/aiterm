import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// New Broadcast hosted in a window, driven by its keys: ⌘↩ is Continue only once step 1 has a
/// project, and a Jira project picked from its list adds its chip and its linked projects.
@MainActor
@Suite(.serialized, .enabled(if: !LoginSession.isLocked, "a window cannot become key while the screen is locked"))
struct NewBroadcastSheetTests {
    private static let pay = JiraProjectRef(id: "10001", key: "PAY", name: "Payments", siteURL: URL(string: "https://pauwels.atlassian.net")!)
    private let webshop = Project(id: UUID(), name: "webshop", path: "/tmp/webshop", provider: .gitlab, remoteUrl: nil,
                                  addedAt: Date(), collapsed: false, jiraProjects: [Self.pay])
    private let blog = Project(id: UUID(), name: "blog", path: "/tmp/blog", provider: .github, remoteUrl: nil,
                               addedAt: Date(), collapsed: false)

    private struct Harness {
        let model: NewBroadcastModel
        let host: NSHostingView<NewBroadcastSheet>
        let window: NSWindow
    }

    private func harness() -> Harness {
        let model = NewBroadcastModel(projects: [webshop, blog], slices: .none, skills: { _, _ in [] }) { _ in UUID() }
        let host = NSHostingView(rootView: NewBroadcastSheet(model: model))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = testWindow(contentRect: host.frame, styleMask: [])
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle(host)
        return Harness(model: model, host: host, window: window)
    }

    private func commandReturn(in h: Harness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host)
    }

    /// Prompt, Review and Done are prompt editors; step 1 has none.
    private func onAPromptStep(_ h: Harness) -> Bool { !descendants(of: NSTextView.self, in: h.host).isEmpty }

    @Test func commandReturnMovesOnOnlyWithAProject() {
        let h = harness()
        defer { h.window.orderOut(nil) }
        commandReturn(in: h)
        #expect(!onAPromptStep(h), "no project: Continue is disabled, and so is its key")
        h.model.add(project: blog)
        settle(h.host)
        commandReturn(in: h)
        #expect(onAPromptStep(h), "on to Prompt")
    }

    @Test func aJiraProjectPickedFromItsListAddsItsChipAndProjects() throws {
        let h = harness()
        defer { h.window.orderOut(nil) }
        let field = try #require(descendants(of: NSTextField.self, in: h.host).first { $0.placeholderString == "Add a Jira project" })
        #expect(h.window.makeFirstResponder(field))
        settle(h.host)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let accepted = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) ?? false
        #expect(accepted, "focusing the field opened its list, and ↩ picks the first")
        settle(h.host)
        #expect(h.model.jiraProjects == [Self.pay])
        #expect(h.model.projects == [webshop], "its linked project comes with it")
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews { matches += descendants(of: type, in: subview) }
        return matches
    }
}
