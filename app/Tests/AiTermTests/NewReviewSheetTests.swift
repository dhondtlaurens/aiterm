import AppKit
import Observation
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@Suite @MainActor struct NewReviewSheetTests {
    @Test func theAgentStepShowsTheModelsDefaultReasoning() throws {
        let model = AgentModel(id: "m", label: "Model", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
        let view = AgentStep(availableAgents: [.claude], models: [model], catalogueLoaded: true,
                             agent: .claude, model: "m", reasoning: .constant(nil), selectAgent: { _ in }, setModel: { _ in })
        let host = testHost(view, size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        func reasoning(in view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton, button.itemTitles == ["Low", "High"] { return button }
            return view.subviews.lazy.compactMap { reasoning(in: $0) }.first
        }
        settle(host, until: { reasoning(in: host) != nil })
        #expect(try #require(reasoning(in: host)).titleOfSelectedItem == "High")
    }

    /// The Review step needs both a name and a branch. Unlike a task, a review derives neither —
    /// there is nothing to fall back on if the branch is blank.
    @Test func theReviewStepNeedsBothANameAndABranch() {
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "", branch: "", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "", creating: false))
        #expect(NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "feat-x", creating: false))
        #expect(NewReviewSheet.canAdvance(step: 2, title: "Review", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "feat-x", creating: true))
    }

    @Test func testWhitespaceIsNotAName() {
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "   ", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "  ", creating: false))
    }

    private static let project = Project.make(name: "acme-web", path: "/p", provider: .gitlab, addedAt: Date())

    /// Opening in a task instead of a new worktree must never be a surprise, so both places the
    /// sheet says where the review goes say which: the destination line, on steps 1 and 3, and the
    /// button.
    @Test func testTheSheetSaysWhetherTheReviewOpensInATask() {
        let owner = TaskItem.make(project: UUID(), title: "Gift card", branch: "feat/gift-card", worktreePath: "/p/.worktrees/gift-card",
            model: "sonnet", appendTicket: true, createdAt: Date())
        for step in [3] {
            #expect(NewReviewSheet.destination(step: step, project: Self.project, owner: owner, slug: "review-gift-card",
                                               branch: "feat/gift-card")?.text
                    == "Opens in iTerm2 · task “Gift card” · feat/gift-card")
            #expect(NewReviewSheet.destination(step: step, project: Self.project, owner: nil, slug: "review-gift-card",
                                               branch: "feat/gift-card")?.text
                    == "Opens in iTerm2 · acme-web/.worktrees/review-gift-card · feat/gift-card")
        }
        #expect(NewReviewSheet.destination(step: 1, project: Self.project, owner: owner, slug: "review-gift-card",
                                           branch: "feat/gift-card") == nil, "only the last step sums up")
        #expect(NewReviewSheet.destination(step: 1, project: Self.project, owner: nil, slug: "", branch: "") == nil,
                "nothing to say before a branch is picked")
        #expect(NewReviewSheet.createLabel(owner: owner) == "Open in Task")
        #expect(NewReviewSheet.createLabel(owner: nil) == "Create Review")
        var review = owner
        review.kind = .review
        #expect(NewReviewSheet.destination(step: 3, project: Self.project, owner: review, slug: "review-gift-card",
                                           branch: "feat/gift-card")?.text
                == "Opens in iTerm2 · review “Gift card” · feat/gift-card")
        #expect(NewReviewSheet.createLabel(owner: review) == "Open in Review")
    }

    /// Finding the unused worktree slug looks at the disk, so step 2, which draws no destination,
    /// never asks for it.
    @Test func theDestinationAsksForTheSlugOnlyWhereItIsDrawn() {
        var reads = 0
        func slug() -> String { reads += 1; return "review-gift-card" }
        #expect(NewReviewSheet.destination(step: 2, project: Self.project, owner: nil, slug: slug(), branch: "feat/x") == nil)
        #expect(reads == 0)
        #expect(NewReviewSheet.destination(step: 3, project: Self.project, owner: nil, slug: slug(), branch: "feat/x")?.text
                == "Opens in iTerm2 · acme-web/.worktrees/review-gift-card · feat/x")
        #expect(reads == 1)
    }

    /// Every sheet that opens a window says where in one format; a terminal opens in the project
    /// folder itself, and a detached checkout has no branch to name.
    @Test func everyDestinationSharesOneFormat() {
        #expect(Destination.projectFolder(Self.project, branch: "main").text == "Opens in iTerm2 · acme-web · main")
        #expect(Destination.projectFolder(Self.project, branch: "").text == "Opens in iTerm2 · acme-web")
        #expect(Destination.worktree(project: Self.project, slug: "shop-1711-monorepo", branch: "feat/shop-1711-monorepo").text
                == "Opens in iTerm2 · acme-web/.worktrees/shop-1711-monorepo · feat/shop-1711-monorepo")
    }

    /// With no CLI installed every segment is disabled — none of them would open anything — and
    /// the note sends the user to where the CLIs are installed.
    @Test func anAgentIsSelectableOnlyWhenItsCLIIsInstalled() {
        #expect(AgentStep.missingAgentNote(available: Set(AgentKind.allCases)) == nil)
        #expect(AgentStep.missingAgentNote(available: [.claude, .codex])
                == "PI isn’t installed. Install it in Settings › Agents.")
        #expect(AgentStep.missingAgentNote(available: [.codex])
                == "Claude Code and PI aren’t installed. Install them in Settings › Agents.")
        #expect(AgentStep.missingAgentNote(available: [])
                == "Claude Code, Codex and PI aren’t installed. Install them in Settings › Agents.")
    }

    @MainActor @Test func completedEmptyCatalogueDoesNotLookLikeItIsStillLoading() {
        let view = AgentStep(availableAgents: [.pi], models: [], catalogueLoaded: true,
                             agent: .pi, model: "", reasoning: .constant(nil),
                             selectAgent: { _ in }, setModel: { _ in })
        let host = testHost(view, size: CGSize(width: Sheet.width, height: 260))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host) { host.fittingSize.height > 0 }
        #expect(host.fittingSize.height > 0)
        #expect(AgentStep.modelPlaceholder(agent: .pi, catalogueLoaded: true) == "No PI providers are signed in. Run /login in PI.")
        #expect(AgentStep.modelPlaceholder(agent: .claude, catalogueLoaded: true) == "No models are available.")
        #expect(AgentStep.modelPlaceholder(agent: .pi, catalogueLoaded: false) == "Loading models…")
    }

    @MainActor @Test func missingSavedModelDoesNotVisuallySelectTheFirstCurrentModel() {
        let current = AgentModel(id: "openai/current", label: "openai / current", detail: nil,
                                 efforts: ["high"], defaultEffort: "high")
        let view = AgentStep(availableAgents: [.pi], models: [current], catalogueLoaded: true,
                             agent: .pi, model: "", reasoning: .constant(nil),
                             selectAgent: { _ in }, setModel: { _ in })
        #expect(view.selectedModel == nil)
        #expect(view.fields.modelChoices.first?.id == "")
        #expect(view.fields.modelChoices.first?.label == "Choose a current model…")
    }
}

/// The keys, driven through a hosted sheet rather than through `DropdownKeys` — which is a
/// pure function and so says nothing about how this sheet composes two pickers and a footer.
/// Mirrors `NewTaskSheetKeyboardTests`, which drives the field's delegate the same way.
@MainActor
@Suite(.serialized) struct NewReviewSheetKeyboardTests {
    // `harness` defaults to these two, and a default argument is evaluated outside the
    // suite's actor, so they cannot inherit its `@MainActor`. `MergeRequest` is `Sendable`.
    private nonisolated static let first = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                                                        targetBranch: "main", author: "L", state: "opened", draft: false,
                                                        url: "https://git.example.net/x/-/merge_requests/4")
    private nonisolated static let second = MergeRequest(iid: 7, title: "Drop the legacy importer", sourceBranch: "chore-drop-importer",
                                                         targetBranch: "main", author: "S", state: "opened", draft: true,
                                                         url: "https://git.example.net/x/-/merge_requests/7")

    /// Collects the drafts the sheet asks to create. A class so the sheet's escaping closure and
    /// the test see the same box.
    @MainActor private final class Created { var drafts: [ReviewDraft] = [] }

    /// Keeps `create()` on the failure branch, which leaves the sheet up. A hosted sheet has no
    /// presentation for `dismiss()` to close, and SwiftUI crashes rather than shrugging.
    private struct Refused: Error, LocalizedError { var errorDescription: String? { "Refused." } }

    private struct Harness {
        let model: ReviewCreationModel
        let host: NSHostingView<NewReviewSheet>
        let window: NSWindow
        let created: Created
    }

    private func harness(step: Int = 1, mergeRequests: [MergeRequest] = [first, second],
                         branches: [String] = ["main", "feat-gift-card", "chore-drop-importer"],
                         title: String = "", branch: String = "",
                         mrOpen: Bool = true, branchOpen: Bool = false,
                         createFails: Bool = false) -> Harness {
        let project = Project.make(name: "acme-web", path: "/tmp/p", provider: .gitlab, remoteUrl: "git@git.example.net:web/acme-web.git",
            addedAt: Date())
        let created = Created()
        let model = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                        context: .scratch(availableAgents: { [.claude] }), searchMergeRequests: { _ in mergeRequests },
                                        createReview: { draft in
                                            created.drafts.append(draft)
                                            if createFails { throw Refused() }
                                        }, recover: { _ in })
        model.branches = branches
        model.branchQuery = "main"
        model.branchQuery = ""
        if !title.isEmpty { model.draft.setTitle(title) }
        if !branch.isEmpty { model.draft.setBranch(branch) }
        // The search's answer, as `.task` would land it; a bare `NSHostingView` never runs it.
        model.results = mergeRequests
        let sheet = NewReviewSheet(model: model).seeded(step: step, mergeRequestsOpen: mrOpen, branchesOpen: branchOpen)
        let host = testHost(sheet, size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        host.layoutSubtreeIfNeeded()
        settle(host)
        return Harness(model: model, host: host, window: window, created: created)
    }

    private static let mrPlaceholder = "Search by !number, title or branch"
    private static let branchPlaceholder = "feat/my-task"

    private func field(_ placeholder: String, in host: NSView) -> NSTextField? {
        host.descendants(NSTextField.self).first { $0.placeholderString == placeholder }
    }

    private func send(_ selector: Selector, to field: NSTextField) -> Bool {
        field.delegate?.control?(field, textView: NSTextView(), doCommandBy: selector) ?? false
    }

    /// Whether that picker's list is open, asked the only way the rendered sheet answers it: an
    /// open list with rows takes ↓, a closed one hands it back.
    private func listIsOpen(_ placeholder: String, in host: NSView) -> Bool {
        guard let field = field(placeholder, in: host) else { return false }
        return send(#selector(NSResponder.moveDown(_:)), to: field)
    }

    private func pressEscape(_ h: Harness) {
        let escape = keyDown("\u{1b}", code: 53, in: h.window)!
        _ = h.window.performKeyEquivalent(with: escape)
        settle(h.host)
    }

    private func pressCommandReturn(_ h: Harness) {
        let event = keyDown("\r", code: 36, modifiers: [.command], in: h.window)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host, for: 0.1)
    }

    /// ↓ then ⏎ on the merge-request field picks the highlighted merge request, which fills the
    /// review's name and its branch — so both other fields change shape at once.
    @Test func arrowDownAndReturnSelectTheMergeRequestAndFillTheBranch() throws {
        let h = harness()
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(Self.mrPlaceholder, in: h.host))
        #expect(send(#selector(NSResponder.moveDown(_:)), to: field))
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        settle(h.host)
        #expect(h.model.draft.mr == Self.second)
        #expect(self.field(Self.mrPlaceholder, in: h.host) == nil)
        #expect(self.field("Describe the review", in: h.host)?.stringValue == "Drop the legacy importer")
        #expect(self.field(Self.branchPlaceholder, in: h.host)?.stringValue == "chore-drop-importer")
    }

    /// The key contract, and the part that is this sheet's alone: it is the only sheet in
    /// the app with two pickers, so ⎋ has three things it could mean. It closes the merge-request
    /// list first, then the branch list, and only then does it reach the sheet.
    @Test func escapeClosesTheMergeRequestListBeforeTheBranchList() throws {
        let h = harness(mrOpen: true)
        defer { h.window.orderOut(nil) }
        #expect(listIsOpen(Self.mrPlaceholder, in: h.host))
        pressEscape(h)
        #expect(!listIsOpen(Self.mrPlaceholder, in: h.host))
        #expect(self.field(Self.mrPlaceholder, in: h.host) != nil)
        #expect(h.created.drafts.isEmpty)
    }

    /// The sheet presented as the app presents it, over a window of its own: a dismiss closes it, which
    /// a bare hosting window has no presentation for.
    private struct Shown {
        let model: ReviewCreationModel
        let window: NSWindow
        let sheetWindow: NSWindow
        let content: NSView
        let presented: Presented
        var isOpen: Bool { presented.isOn }
    }

    private func presenting(step: Int, mrOpen: Bool = false) throws -> Shown {
        let project = Project.make(name: "acme-web", path: "/tmp/p", provider: .gitlab, remoteUrl: "git@git.example.net:web/acme-web.git",
                                   addedAt: Date())
        let model = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                        context: .scratch(availableAgents: { [.claude] }, git: NoPickerGit()),
                                        searchMergeRequests: { _ in [Self.first, Self.second] },
                                        createReview: { _ in throw Refused() }, recover: { _ in })
        model.draft.setTitle("Review it")
        model.draft.setBranch("main")
        model.results = [Self.first, Self.second]
        let presented = Presented()
        let sheet = NewReviewSheet(model: model).seeded(step: step, mergeRequestsOpen: mrOpen)
        let host = NSHostingView(rootView: Color.clear.sheet(isPresented: Binding(get: { presented.isOn }, set: { presented.isOn = $0 })) { sheet })
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width + 100, height: Sheet.settingsHeight + 100)
        let window = testWindow(hosting: host, styleMask: [.titled])
        pumpRunLoop(describing: "the sheet to be presented") { window.attachedSheet != nil }
        let sheetWindow = try #require(window.attachedSheet)
        let content = try #require(sheetWindow.contentView)
        settle(content)
        return Shown(model: model, window: window, sheetWindow: sheetWindow, content: content, presented: presented)
    }

    private func pressEscape(_ s: Shown) {
        let escape = keyDown("\u{1b}", code: 53, in: s.sheetWindow)!
        _ = s.sheetWindow.performKeyEquivalent(with: escape)
        settle(s.content)
    }

    /// With no list open, ⎋ cancels the sheet on any step; Back and the completed steps go back.
    @Test func escapeWithNoListOpenCancelsTheSheet() async throws {
        let s = try presenting(step: 2)
        defer { s.window.orderOut(nil) }
        #expect(self.field(Self.mrPlaceholder, in: s.content) == nil)
        pressEscape(s)
        await eventually(describing: "the sheet to close") { !s.isOpen }
        #expect(s.model.creating == false)
    }

    /// Leaving step 1 closes its lists, so ⎋ on step 2 has none to close, and cancels.
    @Test func leavingStepOneClosesItsListsSoEscapeOnStepTwoCancels() async throws {
        let s = try presenting(step: 1, mrOpen: true)
        defer { s.window.orderOut(nil) }
        let event = keyDown("\r", code: 36, modifiers: [.command], in: s.sheetWindow)!
        _ = s.sheetWindow.performKeyEquivalent(with: event)
        settle(s.content, for: 0.1)
        #expect(self.field(Self.mrPlaceholder, in: s.content) == nil, "on step 2")
        pressEscape(s)
        await eventually(describing: "the sheet to close") { !s.isOpen }
    }

    /// The branch list sits on step 1 with the merge request's: ⎋ closes it before it reaches the
    /// footer's Cancel.
    @Test func escapeClosesTheBranchListOnTheReviewStep() throws {
        let h = harness(title: "Review it", branch: "main", mrOpen: false, branchOpen: true)
        defer { h.window.orderOut(nil) }
        h.model.branchQuery = ""
        settle(h.host)
        #expect(listIsOpen(Self.branchPlaceholder, in: h.host))
        pressEscape(h)
        #expect(!listIsOpen(Self.branchPlaceholder, in: h.host))
        #expect(self.field(Self.mrPlaceholder, in: h.host) != nil)
    }

    /// The prompt's completion popup is a list too: on step 2, ⎋ closes only the popup, and the
    /// next one cancels the sheet. The footer's hidden ⎋ button hears the key before the text view
    /// does, so the popup is the frame's to close (docs/keyboard.md).
    @Test func escapeClosesTheCompletionPopupBeforeCancelling() async throws {
        let s = try presenting(step: 2)
        defer { s.window.orderOut(nil) }
        s.model.completions.visible = [AgentCompletion(name: "review", kind: .command, detail: nil, source: .user)]
        settle(s.content)
        #expect(!s.content.descendants(NSTextView.self).isEmpty, "step 2: Prompt")
        try #require(s.model.completions.isOpen, "the popup is open before ⎋")

        pressEscape(s)
        #expect(!s.model.completions.isOpen, "⎋ closed the popup")
        #expect(s.isOpen, "and only the popup: the sheet is still up")
        #expect(!s.content.descendants(NSTextView.self).isEmpty, "on step 2")

        pressEscape(s)
        await eventually(describing: "the next ⎋ to close the sheet") { !s.isOpen }
    }

    /// The primary button answers ⌘↩ only, the keycaps it shows; a plain ↩ leaves step 1 up.
    @Test func plainReturnDoesNotPressThePrimaryButton() throws {
        let h = harness(title: "Review it", branch: "main", mrOpen: false, createFails: true)
        defer { h.window.orderOut(nil) }
        let event = keyDown("\r", code: 36, in: h.window)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host, for: 0.1)
        #expect(self.field(Self.mrPlaceholder, in: h.host) != nil)
        #expect(h.created.drafts.isEmpty)
    }

    /// ⌘↩ does what the primary button says: Continue on steps 1 and 2, Create Review on step 3.
    @Test func commandReturnAdvancesEachStepAndCreatesOnTheLast() async throws {
        let h = harness(title: "Review it", branch: "main", mrOpen: false, createFails: true)
        defer { h.window.orderOut(nil) }
        #expect(self.field(Self.mrPlaceholder, in: h.host) != nil)
        pressCommandReturn(h)
        #expect(!h.host.descendants(NSTextView.self).isEmpty)
        #expect(h.created.drafts.isEmpty)
        pressCommandReturn(h)
        await eventually { h.model.catalogueLoaded }
        settle(h.host)
        #expect(!h.host.descendants(NSPopUpButton.self).isEmpty)
        #expect(h.created.drafts.isEmpty)
        pressCommandReturn(h)
        await eventually { !h.created.drafts.isEmpty }
        #expect(h.created.drafts.count == 1)
        #expect(h.created.drafts.first?.title == "Review it")
        #expect(h.created.drafts.first?.branch == "main")
        #expect(h.model.error == CreationFailure(reason: "Refused.", detail: nil))
        #expect(!h.host.descendants(NSPopUpButton.self).isEmpty)
    }
}

/// Whether a test's sheet is presented, which the sheet's own dismiss sets back.
@Observable private final class Presented {
    var isOn = true
}
