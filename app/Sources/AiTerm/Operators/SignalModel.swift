import Foundation
import Observation
import AiTermCore

@Observable @MainActor final class SignalModel: Identifiable {
    nonisolated let id = UUID()
    static let stepNames = ["Signal", "Starts when", "Agents", "Prompt", "Done when"]
    /// Each step's number, its place in `stepNames`. The agents come before the prompt so its `/`
    /// completions follow a choice already made.
    static let nameStep = 1, startStep = 2, agentsStep = 3, promptStep = 4, doneStep = 5
    let projects: [Project], context: SignalContext
    private let original: Signal?, createdAt: Date
    private let seen: [SignalSeen]
    var name = ""
    var start = SignalTrigger(source: .jira, query: "") { didSet { startWriting.edited(from: oldValue, to: start) } }
    var done = SignalTrigger(source: .jira, query: "") { didSet { doneWriting.edited(from: oldValue, to: done) } }
    /// Each trigger's Write button: whether Claude is writing its query, whether the query in the field is the one Claude
    /// wrote and AiTerm checked, and why the last write failed.
    private(set) var startWriting = QueryWriting()
    private(set) var doneWriting = QueryWriting()
    var prompt = ""
    var ticketDescription = true
    var requestDescription = true
    private(set) var agentRows: [AgentChoiceRow]
    var mergeWhenReady = false
    var then = SignalFinish.Then.archive
    var deleteMergedBranch = false
    private(set) var starting = false
    /// Why the last save failed, as one sentence.
    private(set) var error: String?
    private(set) var previewItems: [SignalItem] = []
    private(set) var startCount: Int?
    private(set) var previewError: String?
    private(set) var previewing = false
    let completions = PromptCompletions()
    /// The query and description editors offer no completions.
    let startCompletions = PromptCompletions(), doneCompletions = PromptCompletions()
    let startDescribeCompletions = PromptCompletions(), doneDescribeCompletions = PromptCompletions()
    @ObservationIgnored var readiness: @MainActor ([AgentKind]) -> SignalReadiness = { _ in .ready }
    @ObservationIgnored private var previewKey: UUID?
    @ObservationIgnored private let readPreview: @MainActor (SignalTrigger) async throws -> SignalRead
    @ObservationIgnored private let save: @MainActor (Signal) async throws -> Void
    /// Writes a trigger's query from its description, as a Start (`true`) or Done trigger: `QueryWriterRunner` in the app.
    @ObservationIgnored var writeQuery: @MainActor (SignalTrigger, Bool) async -> QueryWriterRunner.Outcome = { _, _ in
        .failed("AiTerm can’t write queries here.", query: nil)
    }
    @ObservationIgnored var loadCompletions: @MainActor () async -> Void = {}
    @ObservationIgnored var checkReadiness: @MainActor () async -> Void = {}

    init(signal: Signal? = nil, projects: [Project], context: SignalContext, seen: [SignalSeen] = [], at: Date = Date(),
         preview: @escaping @MainActor (SignalTrigger) async throws -> SignalRead = { _ in SignalRead(items: [], complete: true) },
         save: @escaping @MainActor (Signal) async throws -> Void) {
        self.original = signal; self.createdAt = signal?.createdAt ?? at; self.projects = projects; self.context = context; self.seen = seen
        self.readPreview = preview; self.save = save
        agentRows = (signal?.agents ?? ModelChoice.pair.compactMap { context.defaults[$0] }).map { choice in
            var choice = choice
            if let model = context.models[choice.agent]?.first(where: { $0.id == choice.model }) {
                var preference = ModelPreference(model: choice.model, reasoning: choice.reasoning)
                preference.select(model); choice.reasoning = preference.reasoning
            }
            return AgentChoiceRow(choice: choice)
        }
        guard let signal else { return }
        name = signal.name; prompt = signal.work.prompt; start = signal.start; done = signal.done
        ticketDescription = signal.work.ticketDescription; requestDescription = signal.work.requestDescription
        then = signal.finish.then; mergeWhenReady = signal.finish.mergesWhenReady
        deleteMergedBranch = signal.finish.deletesMergedBranch
    }
    /// Whether the sheet edits a saved signal rather than making a new one.
    var isEditing: Bool { original != nil }
    var title: String { isEditing ? "Edit signal" : "New signal" }
    var createLabel: String { isEditing ? "Save" : "Create Signal" }
    /// What the match preview reads: the Start trigger's source and query.
    var startKey: String { start.source.rawValue + "\n" + start.query }
    /// Why AiTerm will not run the typed Start or Done query, once there is one; Jira checks its own.
    var startRefusal: QueryRefusal? { refusal(of: start, start: true) }
    var doneRefusal: QueryRefusal? { refusal(of: done, start: false) }
    private func refusal(of trigger: SignalTrigger, start: Bool) -> QueryRefusal? {
        trigger.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trigger.refusal(start: start)
    }
    /// Merge when ready is offered where the Start trigger's merge requests are the person's own.
    var offersMerge: Bool { start.offersMerge }
    var finish: SignalFinish {
        SignalFinish(then: then, mergesWhenReady: offersMerge && mergeWhenReady, deletesMergedBranch: then == .remove && deleteMergedBranch)
    }
    private var signal: Signal {
        func trimmed(_ trigger: SignalTrigger) -> SignalTrigger {
            var trigger = trigger
            trigger.query = trigger.query.trimmingCharacters(in: .whitespacesAndNewlines)
            trigger.description = trigger.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return trigger
        }
        return Signal(id: original?.id ?? id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: createdAt,
                      enabled: original?.enabled ?? true, collapsed: original?.collapsed ?? false, start: trimmed(start), done: trimmed(done),
                      work: SignalWork(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                       ticketDescription: ticketDescription, requestDescription: requestDescription), agents: agents, finish: finish)
    }
    var offeredAgents: [AgentKind] { ModelChoice.pair.filter { context.defaults[$0] != nil } }
    func models(for agent: AgentKind) -> [AgentModel] { context.models[agent] ?? [] }
    var agents: [AgentChoice] { var found = Set<AgentChoice>(); return agentRows.map(\.choice).filter { found.insert($0).inserted } }
    var agentsWhyNot: String? {
        guard !agentRows.isEmpty else { return "Add an agent." }
        for row in agentRows {
            let choice = row.choice
            if !offeredAgents.contains(choice.agent) {
                return "\(choice.agent.displayName) isn’t installed. Choose another agent for its row, or remove it."
            }
            if !models(for: choice.agent).contains(where: { $0.id == choice.model }) {
                return ModelReasoningFields.unavailableHelp
            }
        }
        return nil
    }
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
        guard !starting, TaskCreator.isNamed(name) else { return false }
        if step == Self.nameStep { return true }
        guard start.isValid(start: true) else { return false }
        if step == Self.startStep { return true }
        guard !agents.isEmpty, agents.allSatisfy({ choice in
            offeredAgents.contains(choice.agent) && models(for: choice.agent).contains { model in
                model.id == choice.model && (choice.reasoning == nil || model.efforts.contains(choice.reasoning!))
            }
        }) else { return false }
        if step == Self.agentsStep { return true }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return step == Self.promptStep || signal.isValid
    }
    func create() async -> Bool {
        guard canAdvance(step: Self.doneStep) else { return false }
        let signal = signal
        starting = true; error = nil; defer { starting = false }
        do { try await save(signal); return true }
        catch { self.error = OperationIssue.reason(of: error); return false }
    }
    func loadPreview() async {
        let key = UUID(), expected = start; previewKey = key
        previewing = true; previewItems = []; startCount = nil; previewError = nil
        defer { if previewKey == key { previewing = false } }
        guard !expected.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewError = "Enter a query to check matches."; return
        }
        // A refused query says why under its field; there is nothing to read.
        guard expected.isValid(start: true) else { return }
        do {
            let read = try await readPreview(expected)
            guard previewKey == key, reads(expected), !Task.isCancelled else { return }
            try received(preview: read)
        } catch {
            guard previewKey == key, reads(expected), !Task.isCancelled else { return }
            previewError = OperationIssue.reason(of: error)
        }
    }
    /// Whether a preview of `trigger` still answers the Start trigger: the same source and query, as `startKey` keys it;
    /// a description edited meanwhile changes nothing the read used.
    private func reads(_ trigger: SignalTrigger) -> Bool { start.source == trigger.source && start.query == trigger.query }
    func writing(start: Bool) -> QueryWriting { start ? startWriting : doneWriting }
    /// Whether the trigger's Write button can be pressed: it has a description and a source AiTerm reads.
    func canWrite(start: Bool) -> Bool {
        let trigger = start ? self.start : done
        if case .unknown = trigger.source { return false }
        return !trigger.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Asks Claude for the trigger's query from its description and puts the answer in the query field, keeping the
    /// description. Only the Write button calls it. A query that still fails is put in the field with the reason.
    func write(start: Bool) async {
        guard canWrite(start: start), !writing(start: start).busy else { return }
        let asked = start ? self.start : done
        setWriting(start) { $0 = QueryWriting(busy: true) }
        let outcome = await writeQuery(asked, start)
        let now = start ? self.start : done
        // A source switched while Claude wrote makes its query the wrong syntax; a description or query edited meanwhile
        // is the person's newer word, which the answer must not replace.
        guard now.source == asked.source, now.description == asked.description, now.query == asked.query else {
            setWriting(start) { $0.busy = false }; return
        }
        let query: String?, error: String?
        switch outcome {
        case .written(let written): query = written; error = nil
        case .failed(let why, let written): query = written; error = why
        }
        if let query { if start { self.start.query = query } else { done.query = query } }
        setWriting(start) { $0 = QueryWriting(written: error == nil, error: error) }
    }
    private func setWriting(_ start: Bool, _ change: (inout QueryWriting) -> Void) {
        if start { change(&startWriting) } else { change(&doneWriting) }
    }
    /// The same complete value is accepted by a source read and by a rendering fixture.
    func received(preview read: SignalRead) throws {
        guard read.complete else { throw IncompleteRead("signal matches") }
        previewItems = read.items
        startCount = SignalStarts.items(in: read.items, signal: original?.id, projects: projects, seen: seen).count
    }
}

/// A trigger's Write button and what it last did.
struct QueryWriting: Equatable {
    /// Claude is writing the query.
    var busy = false
    /// The query in the field is the one Claude wrote and AiTerm checked.
    var written = false
    /// Why the last write gave no checked query.
    var error: String?

    /// The person changed the trigger: an edit clears the error, a new source what was written for the old one.
    mutating func edited(from old: SignalTrigger, to new: SignalTrigger) {
        if old.description != new.description || old.query != new.query { error = nil }
        if old.source != new.source { written = false; error = nil }
    }
}

#if DEBUG
extension SignalModel {
    /// A rendering fixture's trigger in the middle of, or after, a write.
    func seed(writing: QueryWriting, start: Bool) { setWriting(start) { $0 = writing } }
}
#endif
