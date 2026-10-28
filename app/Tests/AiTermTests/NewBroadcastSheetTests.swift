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
        let model = NewBroadcastModel(projects: [webshop, blog], context: NewBroadcastContext(slices: .none), skills: { _, _ in [] }) { _ in UUID() }
        let host = testHost(NewBroadcastSheet(model: model), size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        host.layoutSubtreeIfNeeded()
        settle(host)
        return Harness(model: model, host: host, window: window)
    }

    private func commandReturn(in h: Harness) {
        let event = keyDown("\r", code: 36, modifiers: [.command], in: h.window)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host)
    }

    /// Prompt, Review and Done are prompt editors; step 1 has none.
    private func onAPromptStep(_ h: Harness) -> Bool { !h.host.descendants(NSTextView.self).isEmpty }

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
        let field = try #require(h.host.descendants(NSTextField.self).first { $0.placeholderString == "Add a Jira project" })
        #expect(h.window.makeFirstResponder(field))
        settle(h.host)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let accepted = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) ?? false
        #expect(accepted, "focusing the field opened its list, and ↩ picks the first")
        settle(h.host)
        #expect(h.model.jiraProjects == [Self.pay])
        #expect(h.model.projects == [webshop], "its linked project comes with it")
    }

    /// While the Oracle is off the Done step's goal and extra rounds take no typing; with it on, both do.
    @Test(arguments: [false, true]) func theGoalLocksWhileTheOracleIsOff(oracle: Bool) throws {
        let model = NewBroadcastModel(projects: [webshop], context: .installed(oracle: oracle), skills: { _, _ in [] }) { _ in UUID() }
        model.add(project: webshop)
        model.prompt = "Implement PAY-230"
        let host = testHost(NewBroadcastSheet(model: model).seeded(step: 5), size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle(host)
        let goal = try #require(host.descendants(NSTextView.self).first)
        let rounds = try #require(host.descendants(NSTextField.self).first { $0.isEditable })
        #expect(goal.isEditable == oracle)
        #expect(rounds.isEnabled == oracle)
    }

    /// A Jira project name too long for the field truncates inside its chip: the chip stays within the
    /// field's width, so its ✕ is still on the sheet.
    @Test func aVeryLongChipLabelTruncatesAndKeepsItsRemoveButtonInTheField() {
        final class Measured { var chip: CGSize?; var remove: CGSize? }
        let measured = Measured()
        let fieldWidth: CGFloat = 240
        let name = String(repeating: "Customer Self-Service Platform Modernisation ", count: 6)
        let chip = PickChip(mark: .symbol("circle"), label: name, remove: {})
            .background(GeometryReader { proxy in Color.clear.onAppear { measured.chip = proxy.size } })
        let flow = ChipFlow(spacing: Space.tight) {
            chip
            Color.clear.frame(height: PickChip.lineHeight)
        }
        .frame(width: fieldWidth)
        let host = testHost(flow, size: CGSize(width: fieldWidth, height: 80))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle(host) { measured.chip != nil }
        #expect((measured.chip?.width ?? .infinity) <= fieldWidth, "the chip is \(measured.chip?.width ?? 0) wide in a \(fieldWidth) field")
    }
}
