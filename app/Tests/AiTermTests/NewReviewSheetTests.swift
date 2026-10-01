import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm

@Suite @MainActor struct NewReviewSheetTests {
    /// Step 1 needs both a name and a branch. Unlike a task, a review derives neither — there is
    /// nothing to fall back on if the branch is blank.
    @Test func testStepOneNeedsBothANameAndABranch() {
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "", creating: false))
        #expect(NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "feat-x", creating: true))
    }

    @Test func testWhitespaceIsNotAName() {
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "   ", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "  ", creating: false))
    }

    private static let project = Project(id: UUID(), name: "acme-web", path: "/p", provider: .gitlab,
                                         remoteUrl: nil, addedAt: Date(), collapsed: false)

    /// Opening in a task instead of a new worktree must never be a surprise, so both places the
    /// sheet says where the review goes say which: the destination line, on steps 1 and 3, and the
    /// button.
    @Test func testTheSheetSaysWhetherTheReviewOpensInATask() {
        let owner = TaskItem(id: UUID(), projectId: UUID(), title: "Gift card", branch: "feat/gift-card",
                             worktreePath: "/p/.worktrees/gift-card", baseBranch: "main", jira: nil,
                             agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: true,
                             createdAt: Date(), windowId: nil)
        for step in [1, 3] {
            #expect(NewReviewSheet.destination(step: step, project: Self.project, owner: owner, slug: "review-gift-card",
                                               branch: "feat/gift-card")?.text
                    == "Opens in iTerm2 · task “Gift card” · feat/gift-card")
            #expect(NewReviewSheet.destination(step: step, project: Self.project, owner: nil, slug: "review-gift-card",
                                               branch: "feat/gift-card")?.text
                    == "Opens in iTerm2 · acme-web/.worktrees/review-gift-card · feat/gift-card")
        }
        #expect(NewReviewSheet.destination(step: 2, project: Self.project, owner: owner, slug: "review-gift-card",
                                           branch: "feat/gift-card") == nil, "step 2 is the agent's")
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
        #expect(AgentKind.allCases.allSatisfy { !AgentSegmented.isSelectable($0, available: []) })
        #expect(AgentSegmented.isSelectable(.pi, available: [.pi]))
        #expect(!AgentSegmented.isSelectable(.claude, available: [.pi]))
        #expect(AgentStep.missingAgentNote(available: Set(AgentKind.allCases)) == nil)
        #expect(AgentStep.missingAgentNote(available: [.claude, .codex, .pi])
                == "Grok Build isn’t installed. Install it in Settings › Agents.")
        #expect(AgentStep.missingAgentNote(available: [.claude, .codex])
                == "Grok Build and PI aren’t installed. Install them in Settings › Agents.")
        #expect(AgentStep.missingAgentNote(available: [.codex])
                == "Claude Code, Grok Build and PI aren’t installed. Install them in Settings › Agents.")
        #expect(AgentStep.missingAgentNote(available: [])
                == "Claude Code, Codex, Grok Build and PI aren’t installed. Install them in Settings › Agents.")
    }

    @MainActor @Test func completedEmptyCatalogueDoesNotLookLikeItIsStillLoading() {
        let view = AgentStep(availableAgents: [.pi], models: [], catalogueLoaded: true,
                             agent: .constant(.pi), model: .constant(""), reasoning: .constant(nil),
                             selectAgent: { _ in }, setModel: { _ in })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: 260)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        #expect(AgentStep.modelPlaceholder(agent: .pi, catalogueLoaded: true) == "No PI providers are signed in — run /login in PI.")
        #expect(AgentStep.modelPlaceholder(agent: .claude, catalogueLoaded: true) == "No models are available.")
        #expect(AgentStep.modelPlaceholder(agent: .pi, catalogueLoaded: false) == "Loading models…")
    }

    @MainActor @Test func missingSavedModelDoesNotVisuallySelectTheFirstCurrentModel() {
        let current = AgentModel(id: "openai/current", label: "openai / current", detail: nil,
                                 efforts: ["high"], defaultEffort: "high")
        let view = AgentStep(availableAgents: [.pi], models: [current], catalogueLoaded: true,
                             agent: .constant(.pi), model: .constant(""), reasoning: .constant(nil),
                             selectAgent: { _ in }, setModel: { _ in })
        #expect(view.selectedModel == nil)
        #expect(view.modelChoices.first?.id == "")
        #expect(view.modelChoices.first?.label == "Choose a current model…")
    }
}

/// The keys, driven through a hosted sheet rather than through `SearchPickerKeys` — which is a
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
        let project = Project(id: UUID(), name: "acme-web", path: "/tmp/p", provider: .gitlab,
                              remoteUrl: "git@git.example.net:web/acme-web.git", addedAt: Date(), collapsed: false)
        let created = Created()
        let model = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                        home: ScratchHome.bare, availableAgents: [.claude], catalogue: ScratchHome.catalogue,
                                        defaults: ScratchDefaults.make(), searchMergeRequests: { _ in mergeRequests },
                                        createReview: { draft in
                                            created.drafts.append(draft)
                                            if createFails { throw Refused() }
                                        })
        model.branches = branches
        if !title.isEmpty { model.draft.setTitle(title) }
        if !branch.isEmpty { model.draft.setBranch(branch) }
        var sheet = NewReviewSheet(model: model, previewStep: step, previewMergeRequests: mergeRequests, previewOpen: mrOpen)
        // The branch picker has no preview hook of its own; this is the same `State` seeding the
        // initialiser does for the merge-request one.
        if branchOpen { sheet._branchOpen = State(initialValue: true) }
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle(host)
        return Harness(model: model, host: host, window: window, created: created)
    }

    private func settle(_ host: NSView, for seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    private static let mrPlaceholder = "Search by !number, title or branch"
    private static let branchPlaceholder = "Search branches"

    private func field(_ placeholder: String, in host: NSView) -> NSTextField? {
        descendants(of: NSTextField.self, in: host).first { $0.placeholderString == placeholder }
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
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        _ = h.window.performKeyEquivalent(with: escape)
        settle(h.host)
    }

    private func pressCommandReturn(_ h: Harness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host, for: 0.1)
    }

    /// ↓ then ⏎ on the merge-request field picks the highlighted merge request, which fills the
    /// review's name and its branch — so both other fields change shape at once.
    @Test func arrowDownAndReturnSelectTheMergeRequestAndFillTheBranch() throws {
        let h = harness()
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(Self.mrPlaceholder, in: h.host))
        #expect(self.field(Self.branchPlaceholder, in: h.host) != nil, "no branch picked yet, so the branch field is a search field")

        #expect(send(#selector(NSResponder.moveDown(_:)), to: field))
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        settle(h.host)

        #expect(h.model.draft.mr == Self.second)
        #expect(h.model.draft.title == "Drop the legacy importer")
        #expect(h.model.draft.branch == "chore-drop-importer")
        // Both search fields are gone: each picker draws its selection chrome instead.
        #expect(self.field(Self.mrPlaceholder, in: h.host) == nil)
        #expect(self.field(Self.branchPlaceholder, in: h.host) == nil)
        #expect(descendants(of: NSTextField.self, in: h.host).contains { $0.stringValue == "Drop the legacy importer" },
                "the review name follows the merge request")
    }

    /// Spec §3.4's key contract, and the part that is this sheet's alone: it is the only sheet in
    /// the app with two pickers, so ⎋ has three things it could mean. It closes the merge-request
    /// list first, then the branch list, and only then does it reach the sheet.
    @Test func escapeClosesTheMergeRequestListBeforeTheBranchList() throws {
        let h = harness(mrOpen: true, branchOpen: true)
        defer { h.window.orderOut(nil) }
        #expect(listIsOpen(Self.mrPlaceholder, in: h.host))
        #expect(listIsOpen(Self.branchPlaceholder, in: h.host))

        pressEscape(h)
        #expect(!listIsOpen(Self.mrPlaceholder, in: h.host), "the merge-request list goes first")
        #expect(listIsOpen(Self.branchPlaceholder, in: h.host), "the branch list is still open")

        pressEscape(h)
        #expect(!listIsOpen(Self.branchPlaceholder, in: h.host))
        // Neither ⎋ created or dismissed anything: step 1 is still on screen.
        #expect(self.field("Describe the review", in: h.host) != nil)
        #expect(h.created.drafts.isEmpty)
    }

    /// With no list open, ⎋ falls through to the footer's Back — which on step 1 is Cancel, and on
    /// any later step is one step back.
    @Test func escapeWithNoListOpenStepsBack() throws {
        let h = harness(step: 2, title: "Review it", branch: "main", mrOpen: false)
        defer { h.window.orderOut(nil) }
        #expect(self.field("Describe the review", in: h.host) == nil, "step 2 is the agent step")

        pressEscape(h)
        #expect(self.field("Describe the review", in: h.host) != nil, "⎋ went back to step 1")
    }

    /// A list left open on step 1 is out of sight on step 2, so ⎋ there steps back at once rather
    /// than spending the press on closing a list nobody can see.
    @Test func escapeOnALaterStepStepsBackEvenWithAListLeftOpen() throws {
        let h = harness(title: "Review it", branch: "main", mrOpen: true)
        defer { h.window.orderOut(nil) }
        pressCommandReturn(h)
        #expect(self.field("Describe the review", in: h.host) == nil, "⌘↩ went on to step 2")

        pressEscape(h)
        #expect(self.field("Describe the review", in: h.host) != nil, "one ⎋ went back to step 1")
        #expect(!listIsOpen(Self.mrPlaceholder, in: h.host), "advancing closed the list")
    }

    /// The same when the sheet opens on a later step with a list still marked open.
    @Test func escapeOnAPreviewedLaterStepStepsBack() throws {
        let h = harness(step: 2, title: "Review it", branch: "main", mrOpen: true)
        defer { h.window.orderOut(nil) }
        pressEscape(h)
        #expect(self.field("Describe the review", in: h.host) != nil)
    }

    /// The primary button answers ⌘↩ only, the keycaps it shows; a plain ↩ leaves step 1 up.
    @Test func plainReturnDoesNotPressThePrimaryButton() throws {
        let h = harness(title: "Review it", branch: "main", mrOpen: false, createFails: true)
        defer { h.window.orderOut(nil) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host, for: 0.1)
        #expect(self.field("Describe the review", in: h.host) != nil, "still step 1")
    }

    /// ⌘↩ does what the primary button says: Continue on steps 1 and 2, Create Review on step 3.
    @Test func commandReturnAdvancesEachStepAndCreatesOnTheLast() async throws {
        let h = harness(title: "Review it", branch: "main", mrOpen: false, createFails: true)
        defer { h.window.orderOut(nil) }
        #expect(self.field("Describe the review", in: h.host) != nil, "step 1: Branch")

        pressCommandReturn(h)
        // Step 2 now waits for a real catalogue selection before it can continue. The catalogue
        // is loaded off-main; wait for it rather than assuming the old 50 ms render settle also
        // completed that work.
        for _ in 0..<100 where !h.model.catalogueLoaded { try await Task.sleep(for: .milliseconds(20)) }
        settle(h.host)
        #expect(self.field("Describe the review", in: h.host) == nil)
        #expect(!descendants(of: NSPopUpButton.self, in: h.host).isEmpty, "step 2: Agent, with its model select")
        #expect(h.created.drafts.isEmpty, "Continue must not create")

        pressCommandReturn(h)
        #expect(descendants(of: NSPopUpButton.self, in: h.host).isEmpty)
        #expect(!descendants(of: NSTextView.self, in: h.host).isEmpty, "step 3: Prompt, with its editor")
        #expect(h.created.drafts.isEmpty)

        pressCommandReturn(h)
        // Creation runs in a `Task` the button's action starts; awaiting is what lets it run.
        for _ in 0..<100 where h.created.drafts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(h.created.drafts.count == 1, "step 3's ⌘↩ says Create Review, and creates")
        #expect(h.created.drafts.first?.title == "Review it")
        #expect(h.created.drafts.first?.branch == "main")
        // The failure came back through the sheet's own model, so this really went the whole way.
        #expect(h.model.error == CreationFailure(reason: "Refused.", detail: nil))
        #expect(!descendants(of: NSTextView.self, in: h.host).isEmpty, "a refused create leaves step 3 up to correct")
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews { matches += descendants(of: type, in: subview) }
        return matches
    }
}
