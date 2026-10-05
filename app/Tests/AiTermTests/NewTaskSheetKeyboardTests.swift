import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite(.serialized) struct NewTaskSheetKeyboardTests {
    @Test func arrowDownAndReturnSelectTheNextVisibleTicket() throws {
        let controller = AppController(preferences: .scratch())
        let project = Project(id: UUID(), name: "AiTerm", path: "/tmp", provider: .none,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let draft = TaskDraft.initial(project: project, state: .empty, git: controller.git, home: ScratchHome.bare, defaults: ScratchDefaults.make())
        let tickets = [
            JiraTicket(key: "ML-1", summary: "First ticket", description: nil,
                       issueType: "Task", status: "To Do", url: "https://example/ML-1"),
            JiraTicket(key: "ML-2", summary: "Second ticket", description: nil,
                       issueType: "Task", status: "In Progress", url: "https://example/ML-2"),
        ]
        let sheet = NewTaskSheet(model: controller.makeCreationModel(project: project, draft: draft, jira: nil),
                                 previewStep: 1, previewTickets: tickets)
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let field = try #require(descendants(of: NSTextField.self, in: host)
            .first { $0.placeholderString == "Search by key or title" })
        #expect(window.makeFirstResponder(field))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        #expect(field.currentEditor() != nil)
        let editor = try #require(field.currentEditor() as? NSTextView)

        let moved = field.delegate?.control?(field, textView: editor,
                                             doCommandBy: #selector(NSResponder.moveDown(_:))) ?? false
        let accepted = field.delegate?.control?(field, textView: editor,
                                                doCommandBy: #selector(NSResponder.insertNewline(_:))) ?? false

        #expect(moved)
        #expect(accepted)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()
        let fieldsAfterSelection = descendants(of: NSTextField.self, in: host)
        #expect(!fieldsAfterSelection.contains { $0.placeholderString == "Search by key or title" })
        #expect(fieldsAfterSelection.contains { $0.stringValue == "Second ticket" })
    }

    @Test func ticketSearchFieldTakesFocusWhenItsPopupRequestsIt() throws {
        let state = FocusState()
        let host = NSHostingView(rootView: TicketFieldHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 28)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        _ = try #require(descendants(of: NSTextField.self, in: host).first)

        state.focused = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        let focusedField = try #require(descendants(of: NSTextField.self, in: host).first)
        #expect(focusedField.currentEditor() != nil)
    }

    @Test func ticketSearchFieldTakesFocusWhenInsertedForAnOpenPopup() throws {
        let state = FocusState(focused: true)
        let host = NSHostingView(rootView: TicketFieldHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 28)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        let field = try #require(descendants(of: NSTextField.self, in: host).first)
        #expect(field.currentEditor() != nil)
    }

    /// Going from Agent to Prompt inserts the prompt step into a sheet already on screen; the
    /// caret has to land in the editor without a click, so typing starts the prompt.
    @Test func thePromptStepTakesTheKeyboardWhenItAppears() throws {
        let state = StepState()
        let host = NSHostingView(rootView: PromptStepHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        #expect(descendants(of: PromptTextView.self, in: host).isEmpty)

        state.onPrompt = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()

        let editor = try #require(descendants(of: PromptTextView.self, in: host).first)
        #expect(window.firstResponder === editor)
    }

    private final class StepState: ObservableObject {
        @Published var onPrompt = false
        @Published var text = ""
    }

    private struct PromptStepHarness: View {
        @ObservedObject var state: StepState
        var body: some View {
            if state.onPrompt {
                PromptStep(text: $state.text, agent: .claude, completions: PromptCompletions())
            } else {
                Text("Agent")
            }
        }
    }

    private final class FocusState: ObservableObject {
        @Published var text = ""
        @Published var focused: Bool
        init(focused: Bool = false) { self.focused = focused }
    }

    private struct TicketFieldHarness: View {
        @ObservedObject var state: FocusState
        var body: some View {
            SearchField(placeholder: "Ticket", text: $state.text,
                        focused: $state.focused, onCommand: { _ in false })
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews { matches += descendants(of: type, in: subview) }
        return matches
    }
}
