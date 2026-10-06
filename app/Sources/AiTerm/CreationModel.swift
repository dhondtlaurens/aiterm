import Foundation
import SwiftUI
import AiTermCore

/// Why the last create failed: `reason` is what the footer always shows, `detail` everything else
/// that was said — for a git failure, the command and its whole stderr, in the tooltip.
struct CreationFailure: Equatable {
    let reason: String, detail: String?

    init(reason: String, detail: String?) { self.reason = reason; self.detail = detail }

    /// The error as a sentence, by the banner's rule (`OperationIssue.reason(of:)`): git's failure
    /// lines tidied into one (`GitError.sentence`), any other error's own description.
    init(_ error: Error) {
        reason = OperationIssue.reason(of: error)
        detail = (error as? GitError).map { "git \($0.args.joined(separator: " ")) failed:\n\($0.stderr)" }
    }
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
}

extension CreationKind {
    /// The person's text, trimmed. New Task appends its ticket.
    func composedPrompt(_ text: String, draft: Draft) -> String? {
        AgentCommand.composePrompt(userText: text, ticket: nil, appendTicket: false)
    }
    func draftChanged(from old: Draft, in model: CreationModel<Self>) {}
    func branchesChanged(in model: CreationModel<Self>) {}
    func confirmBeforeSubmit(_ model: CreationModel<Self>) async -> Bool { true }
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
    var availableAgents: Set<AgentKind>
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
    private(set) var error: CreationFailure?
    let completions = PromptCompletions()
    let canChangeWorkspace: @MainActor () -> Bool
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
    /// Written while a body reads `worktreeSlug`, so it must not count as a change to the model.
    @ObservationIgnored private var unusedSlugMemo: (slug: String, unused: String)?

    init(kind: Kind, project: Project, draft: Draft, home: URL, availableAgents: Set<AgentKind>, rememberedModels: [AgentKind: String],
         catalogue: @escaping @Sendable (AgentKind) throws -> [AgentModel], initialCatalogue: [AgentModel]? = nil,
         initialCatalogueFailure: String? = nil, defaults: UserDefaults, git: any GitRunning,
         canChangeWorkspace: @escaping @MainActor () -> Bool,
         search: @escaping @MainActor (String) async throws -> [Item], submit: @escaping @MainActor (Draft) async throws -> Void) {
        var fields = draft
        fields.promptText = ""
        self.kind = kind; self.project = project; self.fields = fields; self.prompt = draft.promptText
        self.home = home; self.availableAgents = availableAgents
        self.rememberedModels = rememberedModels; self.catalogue = catalogue; self.defaults = defaults; self.git = git
        self.initialCatalogue = initialCatalogue.map { (draft.agent, $0, initialCatalogueFailure) }
        self.canChangeWorkspace = canChangeWorkspace
        self.searchItems = search; self.submit = submit
    }

    /// The draft as create submits it, prompt included. A view reading it is not redrawn as the
    /// prompt is typed — that is what keeps a keystroke from redrawing the whole sheet — so one
    /// that draws the prompt reads `promptText`.
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
        let unused = BranchNaming.unused(slug, in: project.path)
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
        let catalogue = try? await BackgroundWork.run {
            var models = handed?.models ?? [], failure = handed?.failure
            if handed == nil {
                do { models = try catalogueProvider(agent) } catch { failure = error.localizedDescription }
            }
            return (models: models, failure: failure,
                    completions: SkillCatalog.discover(agent: agent, projectPath: path, home: home),
                    resolution: ModelSettings.resolution(for: agent, catalog: models, remembered: remembered, defaults: defaults))
        }
        guard !Task.isCancelled, generation == catalogueGeneration, agent == draft.agent, let catalogue else { return }
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
        let found = try? await BackgroundWork.run { Repository(path, git: git).branches() }
        guard !Task.isCancelled else { return }
        branches = found ?? []
    }

    func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }

    func scheduleSearch(text: String) {
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
    func refuse(_ reason: String) { error = CreationFailure(reason: reason, detail: nil) }

    /// False means nothing was created and the same draft can be corrected — notably when git
    /// refuses the branch. Once a checkout exists, the workspace owns its recovery and the form closes.
    func create() async -> Bool {
        guard !creating, canChangeWorkspace(), availableAgents.contains(draft.agent), selectedModelIsCurrent else { return false }
        creating = true; error = nil
        defer { creating = false }
        guard await kind.confirmBeforeSubmit(self) else { return false }
        do { try await submit(draft); return true }
        catch { self.error = CreationFailure(error) }
        return false
    }
}
