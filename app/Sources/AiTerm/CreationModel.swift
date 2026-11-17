import Foundation
import SwiftUI
import AiTermCore

/// Why the last create failed: `reason` is what the footer always shows, `detail` everything else
/// that was said — for a git failure, the command and its whole stderr, in the tooltip —
/// `recovery` the action the footer offers for it, when there is one.
struct CreationFailure: Equatable {
    /// A recovery for a refused create, offered as a button that then creates again. A case,
    /// not a closure, as `OperationIssue.Action` is: the app maps it to its call, and a failure
    /// stays `Equatable`.
    enum Recovery: Equatable {
        /// The project's own folder switched off the review's branch, onto `to`, its default.
        case switchProjectFolder(off: String, to: String)
        /// The review's diverged branch rebased onto origin's.
        case rebase(String)
        /// Explicit consent to an empty first commit on the task's unborn base.
        case initializeRepository(on: String)

        var title: String {
            switch self {
            case .switchProjectFolder(_, let target): "Switch to \(target)"
            case .rebase: "Rebase"
            case .initializeRepository: "Create Empty Commit and Retry"
            }
        }

        var help: String {
            switch self {
            case .switchProjectFolder(_, let target): "Switches the project’s folder to \(target), then creates the review."
            case .rebase(let branch): "Rebases your \(branch) onto origin’s, then creates the review."
            case .initializeRepository(let branch): "Creates an empty first commit on \(branch), then retries task creation. Your staged and unstaged files stay uncommitted in the project folder."
            }
        }
    }

    let reason: String, detail: String?
    let recovery: Recovery?

    init(reason: String, detail: String?, recovery: Recovery? = nil) {
        self.reason = reason; self.detail = detail; self.recovery = recovery
    }

    /// The error as a sentence, by the banner's rule (`OperationIssue.reason(of:)`): git's failure
    /// lines tidied into one (`GitError.sentence`), any other error's own description. A review's
    /// branch in the project's folder offers the switch while the folder has no changes, and a
    /// diverged one the rebase, which its sentence says, as the banner's does for the default branch.
    init(_ error: Error) {
        let gitError: GitError? = if case .commitFailed(_, let cause) = error as? RepositoryInitializationError { cause } else { error as? GitError }
        if case .rebaseConflicted(_, let gitWords) = error as? WorktreeError {
            detail = gitWords
        } else {
            detail = gitError.map { "git \($0.args.joined(separator: " ")) failed:\n\($0.stderr)" }
        }
        switch error as? WorktreeError {
        case .branchInProjectFolder(let branch, _, let target, hasChanges: false)?:
            recovery = .switchProjectFolder(off: branch, to: target)
        case .branchDiverged(let branch, _, _)?:
            recovery = .rebase(branch)
        default:
            if let unborn = error as? UnbornBranchError {
                recovery = .initializeRepository(on: unborn.branch)
            } else if case .commitFailed(let branch, _) = error as? RepositoryInitializationError {
                recovery = .initializeRepository(on: branch)
            } else {
                recovery = nil
            }
        }
        let offer = if case .rebase = recovery { " " + OperationIssue.rebaseOffer } else { "" }
        reason = OperationIssue.reason(of: error) + offer
    }
}

/// What one kind of creation sheet brings to `CreationModel`: what it searches and builds, and what
/// it adds around the draft. `TaskCreation` searches Jira tickets and `ReviewCreation` merge
/// requests. The model calls these at the points where the two sheets differ.
@MainActor
protocol CreationKind {
    associatedtype Draft: AgentDraft & Equatable
    associatedtype Item: Equatable & Sendable
    /// The worktree directory `draft` would get, before `BranchNaming.unused` makes it one not taken.
    func slug(for draft: Draft) -> String
    /// Told after anything in the draft but its prompt changed, with what the draft was before.
    func draftChanged(from old: Draft, in model: CreationModel<Self>)
    /// Told after the branch list was read.
    func branchesChanged(in model: CreationModel<Self>)
    /// The fix a failure offered (`CreationFailure.recovery`), run before the create is tried again.
    func recover(_ recovery: CreationFailure.Recovery) async throws
}

extension CreationKind {
    /// New Task and New Review: three steps — what and where from, the prompt, the agent — the
    /// destination summed up only on the last.
    static var steps: CreationSteps { CreationSteps(count: 3, agentStep: 3, promptSteps: [2], summarizesOnlyOnLast: true) }

    func draftChanged(from old: Draft, in model: CreationModel<Self>) {}
    func branchesChanged(in model: CreationModel<Self>) {}
    /// Kinds with no recovery effects need no implementation.
    func recover(_ recovery: CreationFailure.Recovery) async throws {}
}

/// A creation sheet's step count, footer actions, destination summary and prompt editors.
/// The last step creates; the first offers Cancel and the others Back.
struct CreationSteps: Equatable {
    let count: Int
    /// The step that picks the agent and its model; nil for a sheet that starts no agent of its own.
    let agentStep: Int?
    /// New Signal's Agents step lists permitted worker choices and has no prompt editor.
    var agentsListStep: Int? = nil
    var promptSteps: Set<Int>? = nil
    var summarizesOnlyOnLast = false

    func creates(onStep step: Int) -> Bool { step == count }
    func primaryTitle(onStep step: Int, createLabel: String) -> String { creates(onStep: step) ? createLabel : "Continue" }
    func secondaryTitle(onStep step: Int) -> String { step == 1 ? "Cancel" : "Back" }
    /// Step 1, which names where the window opens, and the last, which opens it. Never the agent's
    /// step, so nothing works the line out there (finding the unused worktree slug looks at the disk).
    func showsDestination(onStep step: Int) -> Bool { summarizesOnlyOnLast ? step == count : step == 1 || step == count }
    /// Why no agent can run, on the create step of a sheet that starts one.
    func saysNoAgentCanRun(onStep step: Int) -> Bool { agentStep != nil && creates(onStep: step) }
    /// The steps past the first that are not the agent's or the Agents list's: a prompt editor, whose completion popup
    /// ⎋ closes.
    func hasPrompt(onStep step: Int) -> Bool { promptSteps?.contains(step) ?? (step > 1 && step != agentStep && step != agentsListStep) }
}

/// The dependencies shared by New Task and New Review; disk and preference sources are explicit.
@MainActor
struct CreationContext {
    var home: URL
    var claudeConfig = ClaudeConfig()
    var availableAgents: @MainActor () -> Set<AgentKind> = { Set(AgentKind.allCases) }
    var rememberedModels: [AgentKind: String] = [:]
    var catalogue: @Sendable (AgentKind) throws -> [AgentModel]
    var initialCatalogue: [AgentModel]? = nil
    var initialCatalogueFailure: String? = nil
    var defaults: UserDefaults
    var git: any GitRunning
    var reservedSlugs: Set<String> = []
    var canChangeWorkspace: @MainActor () -> Bool = { true }
}

/// What the New Task and New Review sheets share: the draft, the chosen agent's model catalogue and
/// prompt completions, the branch list, a debounced search whose stale answers are dropped, and the
/// one create call. `Kind` is the rest (`TaskCreationModel`, `ReviewCreationModel`).
///
/// Observed per property, so a view redraws only for what it reads. The draft's prompt is kept
/// apart from the rest of it for that reason: the editor writes it on every keystroke, and only the
/// prompt step and the command preview draw it.
@MainActor
@Observable
final class CreationModel<Kind: CreationKind> {
    typealias Draft = Kind.Draft
    typealias Item = Kind.Item

    nonisolated let id = UUID()
    let project: Project
    let kind: Kind
    /// The agent CLIs this machine has, read live: one Settings installs while the sheet is up is
    /// offered at once, and the views that read this redraw for it.
    var availableAgents: Set<AgentKind> { context.availableAgents() }
    /// Everything in the draft but its prompt, which reads as empty here.
    private var fields: Draft
    /// The prompt as typed. Observed under its own name, and not through `draft`.
    @ObservationIgnored private var prompt: String
    /// The picker's field: its query, the rows it found and why it failed, searched for a pause after each keystroke.
    let itemSearch: DebouncedSearch<Item>
    var query: String {
        get { itemSearch.query }
        set { itemSearch.query = newValue }
    }
    var results: [Item] {
        get { itemSearch.results }
        set { itemSearch.results = newValue }
    }
    var searchError: String? {
        get { itemSearch.error }
        set { itemSearch.error = newValue }
    }
    var branchesLoaded = false
    var branches: [String] = [] {
        didSet { kind.branchesChanged(in: self) }
    }
    var models: [AgentModel] = []
    private(set) var catalogueLoaded = false
    /// Why the chosen agent has no models to offer, when its catalogue could not be read: PI's own
    /// complaint, shown where the model picker would be.
    private(set) var catalogueFailure: String?
    private(set) var creating = false
    private(set) var error: CreationFailure?
    let completions = PromptCompletions()
    private let context: CreationContext
    var canChangeWorkspace: @MainActor () -> Bool { context.canChangeWorkspace }
    /// The catalogue the draft was built from, for the first load of the draft's own agent — and
    /// why it has no models, when it could not be read, so a failed read is not tried twice.
    @ObservationIgnored private var initialCatalogue: (agent: AgentKind, models: [AgentModel], failure: String?)?
    /// Lists the project's branches, and a review's checkouts.
    var git: any GitRunning { context.git }
    private let submit: @MainActor (Draft) async throws -> Void
    @ObservationIgnored private var catalogueGeneration = 0
    @ObservationIgnored private var resetModel = false
    /// Written while a body reads `worktreeSlug`, so it must not count as a change to the model.
    @ObservationIgnored private var unusedSlugMemo: (slug: String, unused: String)?

    init(kind: Kind, project: Project, draft: Draft, context: CreationContext,
         search: @escaping @MainActor (String) async throws -> [Item], submit: @escaping @MainActor (Draft) async throws -> Void) {
        var fields = draft
        fields.promptText = ""
        self.kind = kind; self.project = project; self.fields = fields; self.prompt = draft.promptText
        self.context = context
        self.initialCatalogue = context.initialCatalogue.map { (draft.agent, $0, context.initialCatalogueFailure) }
        itemSearch = DebouncedSearch(lookup: search); self.submit = submit
    }

    /// The draft as create submits it, prompt included. A view reading it is not redrawn as the
    /// prompt is typed — that is what keeps a keystroke from redrawing the whole sheet — so one
    /// that draws the prompt reads `promptText`. `TaskCreationModelTests.aPromptKeystrokeRedrawsOnlyWhatDrawsThePrompt`
    /// guards it.
    var draft: Draft {
        get {
            var draft = fields
            draft.promptText = prompt
            return draft
        }
        set {
            let old = draft
            promptText = newValue.promptText
            var changed = newValue
            changed.promptText = ""
            guard changed != fields else { return }
            fields = changed
            kind.draftChanged(from: old, in: self)
        }
    }

    /// The prompt as typed, which the prompt step edits; also `draft.promptText`.
    var promptText: String {
        get {
            access(keyPath: \.promptText)
            return prompt
        }
        set {
            guard newValue != prompt else { return }
            withMutation(keyPath: \.promptText) { prompt = newValue }
        }
    }

    /// The worktree directory the sheet names: the one create will make.
    var worktreeSlug: String { unusedSlug(kind.slug(for: fields)) }

    /// `slug` as create will make it, through `BranchNaming.unused`. Remembered per slug, so a
    /// render stats the worktree directory only after the branch changed.
    func unusedSlug(_ slug: String) -> String {
        guard !slug.isEmpty else { return "" }
        if let memo = unusedSlugMemo, memo.slug == slug { return memo.unused }
        let unused = BranchNaming.unused(slug, in: project.path, reserved: context.reservedSlugs)
        unusedSlugMemo = (slug, unused)
        return unused
    }

    var selectedModelIsCurrent: Bool {
        catalogueLoaded && models.contains { $0.id == draft.model }
    }

    /// Whether the draft's agent can run: its CLI is installed and its model is one the catalogue
    /// still offers. Both sheets' agent and prompt steps ask it, and so does `create`.
    var agentIsReady: Bool { availableAgents.contains(draft.agent) && selectedModelIsCurrent }

    /// The segmented picker sets its binding even for a click on the already-selected segment,
    /// and the `.task(id: agent)` reload only re-fires when the agent actually changes.
    func selectAgent(_ agent: AgentKind) {
        guard agent != draft.agent else { return }
        draft.agent = agent
        models = []
        catalogueLoaded = false
        catalogueFailure = nil
        resetModel = true
    }

    func loadAgentCatalogue() async {
        catalogueGeneration += 1
        let generation = catalogueGeneration, agent = draft.agent, path = project.path, home = context.home, claudeConfig = context.claudeConfig
        let remembered = context.rememberedModels[agent], catalogueProvider = context.catalogue
        // UserDefaults is documented as thread-safe; the SDK just does not mark it `Sendable`.
        nonisolated(unsafe) let defaults = context.defaults
        let handed = initialCatalogue?.agent == agent ? initialCatalogue : nil
        initialCatalogue = nil
        let catalogue = await BackgroundWork.run {
            var models = handed?.models ?? [], failure = handed?.failure
            if handed == nil {
                do { models = try catalogueProvider(agent) } catch { failure = error.localizedDescription }
            }
            return (models: models, failure: failure,
                    completions: SkillCatalog.discover(agent: agent, projectPath: path, home: home, claudeConfig: claudeConfig),
                    resolution: ModelSettings.resolution(for: agent, catalog: models, remembered: remembered, defaults: defaults))
        }
        guard !Task.isCancelled, generation == catalogueGeneration, agent == draft.agent else { return }
        models = catalogue.models
        catalogueFailure = catalogue.failure
        catalogueLoaded = true
        completions.all = catalogue.completions
        completions.close()
        let preference: ModelPreference
        let savedModelIsMissing: Bool
        switch catalogue.resolution {
        case .valid(let value): preference = value; savedModelIsMissing = false
        case .missing: preference = ModelPreference(model: "", reasoning: nil); savedModelIsMissing = true
        case .empty: preference = ModelPreference(model: "", reasoning: nil); savedModelIsMissing = false
        }
        if resetModel || savedModelIsMissing || !models.contains(where: { $0.id == draft.model }) {
            draft.model = preference.model
            draft.reasoning = preference.reasoning
            resetModel = false
        }
    }

    func loadBranches() async {
        let path = project.path
        let git = git
        let found = await BackgroundWork.run { Repository(path, git: git).branches() }
        guard !Task.isCancelled else { return }
        branches = found
        branchesLoaded = true
    }

    /// The project's files and folders, read once when the sheet opens, off the main actor as the
    /// branches are, for the prompt's `@` completions.
    func loadProjectFiles() async {
        let path = project.path, git = git
        let found = await BackgroundWork.run { ProjectFiles.list(in: path, git: git) }
        guard !Task.isCancelled else { return }
        completions.files = found
    }

    /// What the project's `.worktreeinclude` selects, read when the sheet opens, off the main actor
    /// as the branches are: the files step 1's checkbox copies and its tooltip names. Empty — and
    /// the checkbox absent — when the project has no such file, nothing matches, or git could not
    /// say. Create reads them again (`TaskCreator`), so this is only what the sheet offers.
    var worktreeIncludes: [String] = []

    func loadWorktreeIncludes() async {
        let repository = Repository(project.path, git: git)
        let found = await BackgroundWork.run {
            Log.git.attempt("Listing what \(WorktreeInclude.fileName) selects in \(repository.path)") {
                try WorktreeInclude.matches(in: repository)
            } ?? []
        }
        guard !Task.isCancelled else { return }
        worktreeIncludes = found
    }

    /// Lets the picker's search go: an answer still to come is dropped.
    func cancelSearch() { itemSearch.cancel() }

    /// The search field's text as it is typed: kept, and searched for after a pause.
    func setQuery(_ text: String) { itemSearch.type(text) }

    /// Back to the default list, as clearing a pick does: an empty query, searched at once.
    func reopenSearch() { setQuery("") }

    /// An answer that arrives after a newer search, or after the search was abandoned, is dropped.
    /// A failure clears the list: rows from an earlier query beside an error about this one would
    /// read as its answer. One source failed and another answered: its rows, and the line saying which failed.
    func search(text: String, debounce: Bool = false) async { await itemSearch.search(text, debounce: debounce) }

    /// The draft moved off the branch the last failure was about.
    func dropFailure() {
        guard error != nil else { return }
        show(nil)
    }

    /// False means nothing was created and the same draft can be corrected — notably when git
    /// refuses the branch. Once a checkout exists, the workspace owns its recovery and the form closes.
    func create() async -> Bool { await create(after: nil) }

    /// The footer's fix for the last failure, then the create it stopped: one press, since the fix
    /// is only ever wanted for the create. A fix that fails says why in the failure's place, and
    /// nothing is created.
    func recoverAndCreate() async -> Bool {
        guard let recovery = error?.recovery else { return false }
        return await create(after: recovery)
    }

    private func create(after recovery: CreationFailure.Recovery?) async -> Bool {
        guard !creating, canChangeWorkspace(), agentIsReady else { return false }
        creating = true; show(nil)
        defer { creating = false }
        if let recovery {
            do { try await kind.recover(recovery) } catch { show(CreationFailure(error)); return false }
        }
        do { try await submit(draft); return true }
        catch { show(CreationFailure(error)) }
        return false
    }

    private func show(_ failure: CreationFailure?) { error = failure }
}
