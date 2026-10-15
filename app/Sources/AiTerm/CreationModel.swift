import Foundation
import SwiftUI
import AiTermCore

/// Why the last create failed: `reason` is what the footer always shows, `detail` everything else
/// that was said — for a git failure, the command and its whole stderr, in the tooltip —
/// `recovery` the fix the footer offers for it, when there is one, and `fix` the problem an agent
/// can be asked to fix (`FixSession`), when it is one.
struct CreationFailure: Equatable {
    /// A fix for a review's refused branch, offered as a button that then creates again. A case,
    /// not a closure, as `OperationIssue.Action` is: the app maps it to its call, and a failure
    /// stays `Equatable`.
    enum Recovery: Equatable {
        /// The project's own folder switched off the review's branch, onto `to`, its default.
        case switchProjectFolder(off: String, to: String)
        /// The review's diverged branch rebased onto origin's.
        case rebase(String)

        var title: String {
            switch self {
            case .switchProjectFolder(_, let target): "Switch to \(target)"
            case .rebase: "Rebase"
            }
        }

        var help: String {
            switch self {
            case .switchProjectFolder(_, let target): "Switches the project’s folder to \(target), then creates the review."
            case .rebase(let branch): "Rebases your \(branch) onto origin’s, then creates the review."
            }
        }
    }

    let reason: String, detail: String?
    let recovery: Recovery?
    /// The problem a Fix hands its agent: a review's diverged branch, or its rebase's conflict.
    let fix: FixRequest?
    /// The sentence that sends the person off to do it themselves — “Rebase it by hand.” — which
    /// `reason` leaves out while a Fix is offered, since the button is the way out then. The footer
    /// puts it back when no fix can help: Fix turned off, its agent not installed, or no fix found.
    let byHand: String?
    /// Once a fix has landed and the create it was for failed again: where the branch as it was is
    /// kept (`FixLanding.keptSentence`), said after the new failure. Never part of the next fix's problem.
    var afterFix: String?

    init(reason: String, detail: String?, recovery: Recovery? = nil) {
        self.reason = reason; self.detail = detail; self.recovery = recovery; fix = nil; byHand = nil
    }

    /// The error as a sentence, by the banner's rule (`OperationIssue.reason(of:)`): git's failure
    /// lines tidied into one (`GitError.sentence`), any other error's own description. A review's
    /// branch in the project's folder offers the switch while the folder has no changes, and a
    /// diverged one the rebase, which its sentence says, as the banner's does for the default branch.
    /// A diverged branch and a conflicted rebase are also problems for a Fix, in `projectPath`; the
    /// conflict's request carries what git said as it stopped.
    init(_ error: Error, projectPath: String) {
        detail = (error as? GitError).map { "git \($0.args.joined(separator: " ")) failed:\n\($0.stderr)" }
        var sentence = OperationIssue.reason(of: error), byHand: String?
        func request(_ branch: String, gitWords: String?, recreateRebase: Bool) -> FixRequest {
            FixRequest(title: "Couldn’t create the review.", reason: sentence, detail: gitWords, projectPath: projectPath,
                       branch: branch, recreateRebase: recreateRebase, retry: .createReview)
        }
        switch error as? WorktreeError {
        case .branchInProjectFolder(let branch, _, let target, hasChanges: false)?:
            recovery = .switchProjectFolder(off: branch, to: target); fix = nil
        case .branchDiverged(let branch, _, _)?:
            recovery = .rebase(branch); fix = request(branch, gitWords: detail, recreateRebase: false)
        case .rebaseConflicted(let branch, let gitWords)?:
            let ending = " " + WorktreeError.rebaseByHand
            if sentence.hasSuffix(ending) { sentence.removeLast(ending.count); byHand = WorktreeError.rebaseByHand }
            recovery = nil; fix = request(branch, gitWords: gitWords, recreateRebase: true)
        default:
            recovery = nil; fix = nil
        }
        self.byHand = byHand
        let offer = if case .rebase = recovery { " " + OperationIssue.rebaseOffer } else { "" }
        reason = sentence + offer
    }

    /// `reason`, and what a landed fix left behind: what the footer says while a fix is offered.
    var shownReason: String { [reason, afterFix].compactMap { $0 }.joined(separator: " ") }
    /// `reason` with `byHand` put back: what the footer says while no fix can help.
    var reasonByHand: String { [reason, byHand, afterFix].compactMap { $0 }.joined(separator: " ") }
}

/// What one kind of creation sheet brings to `CreationModel`: what it searches and builds, and what
/// it adds around the draft. `TaskCreation` searches Jira tickets and `ReviewCreation` merge
/// requests. The model calls these at the points where the two sheets differ.
@MainActor
protocol CreationKind {
    associatedtype Draft: AgentDraft & Equatable
    associatedtype Item: Equatable
    /// The worktree directory `draft` would get, before `BranchNaming.unused` makes it one not taken.
    func slug(for draft: Draft) -> String
    /// The first prompt the command carries, from `text`, the prompt as typed.
    func composedPrompt(_ text: String, draft: Draft) -> String?
    /// Told after anything in the draft but its prompt changed, with what the draft was before.
    func draftChanged(from old: Draft, in model: CreationModel<Self>)
    /// Told after the branch list was read.
    func branchesChanged(in model: CreationModel<Self>)
    /// A last check between the press and the submit, run while `creating` holds off a second
    /// press. `false` stops the create; the kind says why with `model.refuse`.
    func confirmBeforeSubmit(_ model: CreationModel<Self>) async -> Bool
    /// The fix a failure offered (`CreationFailure.recovery`), run before the create is tried again.
    func recover(_ recovery: CreationFailure.Recovery) async throws
    /// Whether an agent's fix for `request` is still about `draft`: its branch is the draft's.
    func fixApplies(_ request: FixRequest, to draft: Draft) -> Bool
}

extension CreationKind {
    /// The person's text, trimmed. New Task appends its ticket.
    func composedPrompt(_ text: String, draft: Draft) -> String? {
        AgentCommand.composePrompt(userText: text, ticket: nil, appendTicket: false)
    }
    func draftChanged(from old: Draft, in model: CreationModel<Self>) {}
    func branchesChanged(in model: CreationModel<Self>) {}
    func confirmBeforeSubmit(_ model: CreationModel<Self>) async -> Bool { true }
    /// Only a review's failures offer a fix, so New Task is never asked for one.
    func recover(_ recovery: CreationFailure.Recovery) async throws {}
    /// Nor for an agent's.
    func fixApplies(_ request: FixRequest, to draft: Draft) -> Bool { false }
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
    var availableAgents: Set<AgentKind> { installedAgents() }
    /// Everything in the draft but its prompt, which reads as empty here.
    private var fields: Draft
    /// The prompt as typed. Observed under its own name, and not through `draft`.
    @ObservationIgnored private var prompt: String
    var query = ""
    var results: [Item] = []
    var searchError: String?
    var branches: [String] = [] {
        didSet { kind.branchesChanged(in: self) }
    }
    var models: [AgentModel] = []
    private(set) var catalogueLoaded = false
    /// Why the chosen agent has no models to offer, when its catalogue could not be read: PI's own
    /// complaint, shown where the model picker would be.
    private(set) var catalogueFailure: String?
    private(set) var creating = false
    /// Written through `show(_:)`, which keeps `fixSession` beside it.
    private(set) var error: CreationFailure?
    /// The Fix offered for the last failure, when it is a problem for one (`CreationFailure.fix`) and
    /// the sheet was given a pipeline: made when the failure is shown, dropped when it goes — unless
    /// it is working, since a Look or an Apply in flight is never let go of mid-way.
    private(set) var fixSession: FixSession?
    /// Set once a create run by a landed fix has succeeded: the sheet closes on it, as on its own create.
    private(set) var createdAfterFix = false
    let completions = PromptCompletions()
    let canChangeWorkspace: @MainActor () -> Bool
    private let installedAgents: @MainActor () -> Set<AgentKind>
    private let rememberedModels: [AgentKind: String]
    /// Whose skills and commands the prompt completes: the person's home in the app.
    private let home: URL
    private let catalogue: @Sendable (AgentKind) throws -> [AgentModel]
    /// The catalogue the draft was built from, for the first load of the draft's own agent — and
    /// why it has no models, when it could not be read, so a failed read is not tried twice.
    @ObservationIgnored private var initialCatalogue: (agent: AgentKind, models: [AgentModel], failure: String?)?
    private let defaults: UserDefaults
    /// Lists the project's branches, and a review's checkouts.
    let git: any GitRunning
    private let searchItems: @MainActor (String) async throws -> [Item]
    private let submit: @MainActor (Draft) async throws -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var catalogueGeneration = 0
    @ObservationIgnored private var resetModel = false
    /// The worktree folders the project's archived rows come back to, which the folder the sheet names skips
    /// as create does.
    let reservedSlugs: Set<String>
    /// Written while a body reads `worktreeSlug`, so it must not count as a change to the model.
    @ObservationIgnored private var unusedSlugMemo: (slug: String, unused: String)?
    /// Settings › Agents' fixer, read as a failure is shown.
    private let fixer: @MainActor () -> FixerResolution
    /// What a Fix runs; nil makes no Fix — New Task's sheet has none.
    private let pipeline: FixPipeline?
    /// Told once a fix's create succeeded, with the landing and the agent that made it: the toast.
    private let fixLanded: @MainActor (FixLanding, FixerAgent) -> Void
    /// Told once a fix landed but no create followed that could say so in its failure — it never
    /// started, or the draft had moved to another branch: the toast naming the backup.
    private let backupKept: @MainActor (FixLanding) -> Void

    init(kind: Kind, project: Project, draft: Draft, home: URL, availableAgents: @escaping @MainActor () -> Set<AgentKind>,
         rememberedModels: [AgentKind: String],
         catalogue: @escaping @Sendable (AgentKind) throws -> [AgentModel], initialCatalogue: [AgentModel]? = nil,
         initialCatalogueFailure: String? = nil, defaults: UserDefaults, git: any GitRunning,
         reservedSlugs: Set<String> = [], canChangeWorkspace: @escaping @MainActor () -> Bool,
         search: @escaping @MainActor (String) async throws -> [Item], submit: @escaping @MainActor (Draft) async throws -> Void,
         fixer: @escaping @MainActor () -> FixerResolution = { .off }, pipeline: FixPipeline? = nil,
         fixLanded: @escaping @MainActor (FixLanding, FixerAgent) -> Void = { _, _ in },
         backupKept: @escaping @MainActor (FixLanding) -> Void = { _ in }) {
        var fields = draft
        fields.promptText = ""
        self.kind = kind; self.project = project; self.fields = fields; self.prompt = draft.promptText
        self.home = home; self.installedAgents = availableAgents
        self.rememberedModels = rememberedModels; self.catalogue = catalogue; self.defaults = defaults; self.git = git
        self.reservedSlugs = reservedSlugs
        self.initialCatalogue = initialCatalogue.map { (draft.agent, $0, initialCatalogueFailure) }
        self.canChangeWorkspace = canChangeWorkspace
        self.searchItems = search; self.submit = submit
        self.fixer = fixer; self.pipeline = pipeline; self.fixLanded = fixLanded; self.backupKept = backupKept
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
        let unused = BranchNaming.unused(slug, in: project.path, reserved: reservedSlugs)
        unusedSlugMemo = (slug, unused)
        return unused
    }

    /// The first prompt the command carries.
    var composedPrompt: String? { kind.composedPrompt(promptText, draft: draft) }

    /// Spec 4.4's "exact command", built without touching disk (`previewCommand`, not `build`): the
    /// sheet shows it on one line and truncates, the tooltip carries the whole thing.
    var previewCommand: String {
        AgentCommand.previewCommand(agent: draft.agent, model: draft.model, reasoning: draft.reasoning, prompt: composedPrompt)
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
        let generation = catalogueGeneration, agent = draft.agent, path = project.path, home = self.home
        let remembered = rememberedModels[agent], catalogueProvider = self.catalogue
        // UserDefaults is documented as thread-safe; the SDK just does not mark it `Sendable`.
        nonisolated(unsafe) let defaults = self.defaults
        let handed = initialCatalogue?.agent == agent ? initialCatalogue : nil
        initialCatalogue = nil
        let catalogue = await BackgroundWork.run {
            var models = handed?.models ?? [], failure = handed?.failure
            if handed == nil {
                do { models = try catalogueProvider(agent) } catch { failure = error.localizedDescription }
            }
            return (models: models, failure: failure,
                    completions: SkillCatalog.discover(agent: agent, projectPath: path, home: home),
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

    func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }

    /// The search field's text as it is typed: kept, and searched for after a pause.
    func setQuery(_ text: String) {
        query = text
        scheduleSearch(text: text)
    }

    /// Back to the default list, as clearing a pick does: an empty query, searched at once.
    func reopenSearch() { setQuery("") }

    private func scheduleSearch(text: String) {
        cancelSearch()
        searchTask = Task { await search(text: text, debounce: true) }
    }

    /// An answer that arrives after a newer search, or after the search was abandoned, is dropped.
    /// A failure clears the list: rows from an earlier query beside an error about this one would
    /// read as its answer.
    func search(text: String, debounce: Bool = false) async {
        searchGeneration += 1
        let generation = searchGeneration
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            let found = try await searchItems(text)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = found; searchError = nil
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = []
            searchError = error.localizedDescription
        }
    }

    /// Stops a create before it starts, saying why in the footer.
    func refuse(_ reason: String) { show(CreationFailure(reason: reason, detail: nil)) }

    enum PrimaryAction: Equatable { case advance, applyFix }

    /// What ⌘↩ and the primary button do: Apply while a fix's proposal is up, else the sheet's own.
    func primaryAction() -> PrimaryAction {
        if case .proposal = fixSession?.state { .applyFix } else { .advance }
    }

    /// Apply on the proposal that is up: the fix made, checked, landed, then the create run again.
    /// Refused while the workspace cannot change — the create after it could not run — and for a
    /// proposal about a branch the draft no longer has.
    func applyFix() {
        guard let session = fixSession, canChangeWorkspace(), kind.fixApplies(session.request, to: draft) else { return }
        session.apply()
    }

    /// The draft moved off what the last failure was about — its branch — so the failure and the
    /// fixes it offered go with it; a fix at work keeps the footer until it ends.
    func dropFailure() {
        guard fixSession?.isBusy != true, error != nil || fixSession != nil else { return }
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
            do { try await kind.recover(recovery) } catch { show(CreationFailure(error, projectPath: project.path)); return false }
        }
        guard await kind.confirmBeforeSubmit(self) else { return false }
        do { try await submit(draft); return true }
        catch { show(CreationFailure(error, projectPath: project.path)) }
        return false
    }

    /// The footer's failure, and the Fix it offers: a new session for a failure that is a problem
    /// for one, none otherwise. Clearing the failure keeps a working session.
    private func show(_ failure: CreationFailure?) {
        error = failure
        if failure == nil, fixSession?.isBusy == true { return }
        let session = failure?.fix.flatMap { request in pipeline.map { makeFixSession(request, pipeline: $0) } }
        guard session !== fixSession else { return }
        // Let go of, not orphaned: a Look stops and a proposal is declined, each removing its clone.
        fixSession?.cancel()
        fixSession = session
    }

    /// Once the fix has landed, the create it stopped runs again; a create that fails shows its own
    /// failure, which may offer a Fix of its own. Whenever no review follows, the person is told
    /// where the branch as it was is kept: after the new failure, or in a toast when there is none.
    private func makeFixSession(_ request: FixRequest, pipeline: FixPipeline) -> FixSession {
        let resolution = fixer()
        let agent: FixerAgent? = if case .ready(let agent) = resolution { agent } else { nil }
        return FixSession(request: request, fixer: resolution, pipeline: pipeline) { [weak self] landing in
            guard let self else { return }
            // A draft on another branch is not the create this fix was for, and the failure still
            // up — held while the fix applied — was about the branch it left.
            guard self.kind.fixApplies(request, to: self.draft) else { return self.landedWithoutCreate(landing) }
            guard await self.create() else {
                // A create that never started — the workspace locked meanwhile — showed nothing, so
                // the landed session is still here, beside the failure the fix answered: let both
                // go, and the footer is the sheet's again.
                if case .done? = self.fixSession?.state { return self.landedWithoutCreate(landing) }
                if self.error != nil { self.error?.afterFix = landing.keptSentence } else { self.backupKept(landing) }
                return
            }
            if let agent { self.fixLanded(landing, agent) }
            self.createdAfterFix = true
        }
    }

    /// A landed fix with no create after it: its failure goes, and the toast names the backup.
    private func landedWithoutCreate(_ landing: FixLanding) {
        show(nil)
        backupKept(landing)
    }
}
