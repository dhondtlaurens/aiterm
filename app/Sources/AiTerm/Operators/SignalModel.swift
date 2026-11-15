import Foundation
import Observation
import AiTermCore

@Observable @MainActor final class SignalModel: Identifiable {
    enum SourceKind: String, CaseIterable { case jira, gitLab, gitHub }
    enum QueryMode: String, CaseIterable { case conditions, jql }
    struct Metadata: Sendable {
        var users: [JiraUser] = []
        var labels: [String] = []
        var statuses: [JiraStatusRef] = []
        var projects: [JiraProjectRef] = []
    }
    nonisolated let id = UUID()
    static let steps = CreationSteps(count: 5, agentStep: nil, agentsListStep: 4, promptSteps: [2, 3], summarizesOnlyOnLast: true)
    static let stepNames = ["Signal", "Starts when", "Prompt", "Agents", "Done"]
    static let jiraPrompt = "/psg:plan, then /psg:implement and /psg:review. Ask me only about scope."
    static let ownRequestPrompt = "/psg:review. Answer every open thread, then run the tests."
    static let reviewPrompt = "/psg:peer-review. Post only Critical and Important findings."
    let projects: [Project], context: SignalContext
    private let original: Signal?, createdAt: Date
    private let seen: [SignalSeen]
    var name = ""
    private(set) var sourceKind = SourceKind.jira
    var queryMode = QueryMode.conditions
    var jira = JiraConditions(labels: ["operator"], inOpenSprints: true)
    var jql = ""
    private(set) var event = RequestConditions.Event.reviewRequested
    var waitingOnMyReply = true
    var sentBackToMe = true
    var requestProjects: [String] = []
    var prompt = SignalModel.jiraPrompt
    var ticketDescription = true
    var requestDescription = true
    private(set) var agentRows: [AgentChoiceRow]
    var done = DoneWhen.hasReviewer
    var status = ""
    var mergeWhenReady = false
    var then = SignalFinish.Then.archive
    var deleteMergedBranch = false
    private(set) var starting = false
    private(set) var error: CreationFailure?
    private(set) var previewItems: [SignalItem] = []
    private(set) var startCount: Int?
    private(set) var previewError: String?
    private(set) var previewing = false
    private(set) var metadata = Metadata()
    private(set) var metadataError: String?
    private(set) var assignees: [JiraUser] = []
    let completions = PromptCompletions()
    let jqlCompletions = PromptCompletions()
    @ObservationIgnored var readinessLines: @MainActor () -> [String] = { [] }
    @ObservationIgnored private var previewKey: UUID?
    @ObservationIgnored private let readPreview: @MainActor (SignalSource) async throws -> SignalRead
    @ObservationIgnored private let readMetadata: @MainActor () async throws -> Metadata
    @ObservationIgnored private let readUsers: @MainActor (String) async throws -> [JiraUser]
    @ObservationIgnored private let save: @MainActor (Signal) async throws -> Void
    @ObservationIgnored private let ready: @MainActor () -> Bool
    @ObservationIgnored var loadCompletions: @MainActor () async -> Void = {}
    @ObservationIgnored var checkReadiness: @MainActor () async -> Void = {}

    init(signal: Signal? = nil, projects: [Project], context: SignalContext, seen: [SignalSeen] = [], at: Date = Date(),
         preview: @escaping @MainActor (SignalSource) async throws -> SignalRead = { _ in SignalRead(items: [], complete: true) },
         metadata: @escaping @MainActor () async throws -> Metadata = { Metadata() },
         users: @escaping @MainActor (String) async throws -> [JiraUser] = { _ in [] },
         ready: @escaping @MainActor () -> Bool = { true }, save: @escaping @MainActor (Signal) async throws -> Void) {
        self.original = signal; self.createdAt = signal?.createdAt ?? at; self.projects = projects; self.context = context; self.seen = seen
        self.readPreview = preview; self.readMetadata = metadata; self.readUsers = users; self.ready = ready; self.save = save
        agentRows = (signal?.agents ?? ModelChoice.pair.compactMap { context.defaults[$0] }).map { AgentChoiceRow(choice: $0) }
        guard let signal else { return }
        name = signal.name; prompt = signal.work.prompt
        ticketDescription = signal.work.ticketDescription; requestDescription = signal.work.requestDescription
        done = signal.finish.doneWhen; then = signal.finish.then; mergeWhenReady = signal.finish.mergesWhenReady
        deleteMergedBranch = signal.finish.deletesMergedBranch
        if case .ticketStatus(let text) = done { status = text; done = .ticketStatus("") }
        switch signal.source {
        case .jira(let conditions):
            jira = conditions; jql = conditions.jql ?? ""; queryMode = jql.isEmpty ? .conditions : .jql
        case .gitLab(let conditions): sourceKind = .gitLab; load(conditions)
        case .gitHub(let conditions): sourceKind = .gitHub; load(conditions)
        case .unknown: break
        }
    }
    private func load(_ conditions: RequestConditions) {
        event = conditions.event; waitingOnMyReply = conditions.waitingOnMyReply; sentBackToMe = conditions.sentBackToMe
        requestProjects = conditions.projects
    }
    var title: String { original == nil ? "New signal" : "Edit signal" }
    var createLabel: String { original == nil ? "Create Signal" : "Save" }
    var source: SignalSource {
        if sourceKind == .jira {
            var conditions = jira; conditions.jql = queryMode == .jql ? jql : nil; return .jira(conditions)
        }
        let conditions = RequestConditions(event: event, waitingOnMyReply: waitingOnMyReply, sentBackToMe: sentBackToMe, projects: requestProjects)
        return sourceKind == .gitLab ? .gitLab(conditions) : .gitHub(conditions)
    }
    var sourceKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    var doneChoices: [DoneWhen] { SignalFinish.choices(for: source) }
    var offersMerge: Bool { done != .merged && (sourceKind == .jira || event == .myRequest) }
    var finish: SignalFinish {
        let condition: DoneWhen = if case .ticketStatus = done { .ticketStatus(status.trimmingCharacters(in: .whitespacesAndNewlines)) } else { done }
        return SignalFinish(doneWhen: condition, then: then, mergesWhenReady: offersMerge && mergeWhenReady,
                            deletesMergedBranch: then == .remove && deleteMergedBranch)
    }
    func selectSource(_ kind: SourceKind) {
        guard kind != sourceKind else { return }
        let old = defaultPrompt; sourceKind = kind
        if prompt == old { prompt = defaultPrompt }
        resetDone()
    }
    func setEvent(_ event: RequestConditions.Event) {
        guard event != self.event else { return }
        let old = defaultPrompt; self.event = event
        if prompt == old { prompt = defaultPrompt }
        resetDone()
    }
    private var defaultPrompt: String { sourceKind == .jira ? Self.jiraPrompt : event == .reviewRequested ? Self.reviewPrompt : Self.ownRequestPrompt }
    private func resetDone() {
        done = sourceKind == .jira ? .hasReviewer : event == .reviewRequested ? .myReviewPosted : .threadsResolved
        mergeWhenReady = false
    }
    var offeredAgents: [AgentKind] { ModelChoice.pair.filter { context.defaults[$0] != nil } }
    func models(for agent: AgentKind) -> [AgentModel] { context.models[agent] ?? [] }
    var agents: [AgentChoice] { var found = Set<AgentChoice>(); return agentRows.map(\.choice).filter { found.insert($0).inserted } }
    func addAgent() {
        guard let agent = offeredAgents.first(where: { agent in !agentRows.contains { $0.choice.agent == agent } }) ?? offeredAgents.first,
              let choice = context.defaults[agent] else { return }
        agentRows.append(AgentChoiceRow(choice: choice))
    }
    func removeAgent(_ id: UUID) { agentRows.removeAll { $0.id == id } }
    func setAgent(_ agent: AgentKind, of id: UUID) {
        guard let choice = context.defaults[agent], let index = agentRows.firstIndex(where: { $0.id == id }),
              agentRows[index].choice.agent != agent else { return }
        agentRows[index].choice = choice
    }
    func setModel(_ model: AgentModel, of id: UUID) {
        guard let index = agentRows.firstIndex(where: { $0.id == id }) else { return }
        var preference = ModelPreference(model: agentRows[index].choice.model, reasoning: agentRows[index].choice.reasoning)
        preference.select(model); agentRows[index].choice.model = preference.model; agentRows[index].choice.reasoning = preference.reasoning
    }
    func setReasoning(_ reasoning: String?, of id: UUID) {
        guard let index = agentRows.firstIndex(where: { $0.id == id }) else { return }; agentRows[index].choice.reasoning = reasoning
    }
    func canAdvance(step: Int) -> Bool {
        guard !starting, TaskCreator.isNamed(name), original?.source.isSupported != false else { return false }
        if step == 1 { return true }
        guard sourceKind != .jira || queryMode != .jql || !jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceKind == .jira || event == .reviewRequested || waitingOnMyReply || sentBackToMe else { return false }
        if step == 2 { return true }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if step == 3 { return true }
        guard !agents.isEmpty, agents.allSatisfy({ choice in
            offeredAgents.contains(choice.agent) && models(for: choice.agent).contains { model in
                model.id == choice.model && (choice.reasoning == nil || model.efforts.contains(choice.reasoning!))
            }
        }) else { return false }
        return step == 4 || (finish.isValid(for: source) && ready())
    }
    func create() async -> Bool {
        guard canAdvance(step: 5) else { return false }
        let signal = Signal(id: original?.id ?? id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: createdAt,
                            enabled: original?.enabled ?? true, collapsed: original?.collapsed ?? false, source: source,
                            work: SignalWork(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                             ticketDescription: ticketDescription, requestDescription: requestDescription), agents: agents, finish: finish)
        starting = true; error = nil; defer { starting = false }
        do { try await save(signal); return true }
        catch { self.error = CreationFailure(reason: OperationIssue.reason(of: error), detail: nil); return false }
    }
    func loadPreview() async {
        let key = UUID(), expected = source; previewKey = key
        previewing = true; previewItems = []; startCount = nil; previewError = nil
        defer { if previewKey == key { previewing = false } }
        guard sourceKind != .jira || queryMode != .jql || !jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewError = "Enter a JQL query to check matches."; return
        }
        do {
            let read = try await readPreview(expected)
            guard previewKey == key, source == expected, !Task.isCancelled else { return }
            try received(preview: read)
        } catch {
            guard previewKey == key, source == expected, !Task.isCancelled else { return }
            previewError = OperationIssue.reason(of: error)
        }
    }
    /// The same complete value is accepted by a source read and by a rendering fixture.
    func received(preview read: SignalRead) throws {
        guard read.complete else { throw IncompleteRead("signal matches") }
        previewItems = read.items
        startCount = read.items.filter { item in
            !ItemProjectMapper.projects(for: item.item, in: projects).isEmpty && !seen.contains {
                $0.signal == original?.id && $0.item.identity == item.item.identity && $0.disposition == .started && $0.isMatching
            }
        }.count
    }
    func received(metadata: Metadata) { self.metadata = metadata; assignees = metadata.users; metadataError = nil }
    func loadMetadata() async {
        do { let value = try await readMetadata(); guard !Task.isCancelled else { return }; received(metadata: value) }
        catch { if !Task.isCancelled { metadataError = OperationIssue.reason(of: error) } }
    }
    func searchAssignees(_ query: String) async {
        do { let users = try await readUsers(query); if !Task.isCancelled { assignees = users } }
        catch { if !Task.isCancelled { assignees = [] } }
    }
}
