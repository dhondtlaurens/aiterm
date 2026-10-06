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
        let model = controller.sheets.makeCreationModel(project: project, draft: draft, jira: nil)
        // The search's answer, as `.task` would land it; a bare `NSHostingView` never runs it.
        model.results = tickets
        let sheet = NewTaskSheet(model: model).seeded(step: 1, ticketsOpen: true)
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

    /// Typing a known type's prefix into the branch field is picking the type
    /// (`TaskDraft.setBranch`), there and then: the select takes `fix`, and the field, still being
    /// typed in, keeps only the name.
    @Test func typingATypePrefixIntoTheBranchFieldPicksTheTypeAsYouType() throws {
        let controller = AppController(preferences: .scratch())
        let project = Project(id: UUID(), name: "AiTerm", path: "/tmp", provider: .none,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let draft = TaskDraft.initial(project: project, state: .empty, git: controller.git, home: ScratchHome.bare, defaults: ScratchDefaults.make())
        let model = controller.sheets.makeCreationModel(project: project, draft: draft, jira: nil)
        let host = NSHostingView(rootView: NewTaskSheet(model: model).seeded(step: 1))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        #expect(model.draft.branchType != .fix)

        let field = try #require(descendants(of: NSTextField.self, in: host)
            .first { $0.placeholderString == "branch-name" })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("fix/login", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        #expect(model.draft.branchType == .fix)
        #expect(model.draft.branchName == "login")
        #expect(field.currentEditor() != nil, "picking the type took the keyboard from the field")
        #expect(field.currentEditor()?.string == "login")
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
