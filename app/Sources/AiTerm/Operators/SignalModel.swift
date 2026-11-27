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
    /// Who runs its tasks: set by where New Signal… was chosen for a new signal, read from the signal when editing. A
    /// project signal has one agent row, You decide in place of the Operator, and merges nothing.
    let kind: Signal.Kind
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
    /// Empty models on new rows follow the worker's default as its probe arrives.
    private var draftRows: [AgentChoiceRow]
    var agentRows: [AgentChoiceRow] {
        let rows = draftRows.filter { !$0.initialDefault || context.worker($0.choice.agent) != nil }
        return (isProject ? Array(rows.prefix(1)) : rows).map(resolved)
    }
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
    @ObservationIgnored var readiness: @MainActor ([AgentKind], Bool) -> SignalReadiness = { _, _ in .ready }
    @ObservationIgnored private var previewKey: UUID?
    @ObservationIgnored private let readPreview: @MainActor (SignalTrigger) async throws -> SignalRead
    @ObservationIgnored private let save: @MainActor (Signal) async throws -> Void
    /// Writes a trigger's query from its description, as a Start (`true`) or Done trigger: `QueryWriterRunner` in the app.
    @ObservationIgnored var writeQuery: @MainActor (SignalTrigger, Bool) async -> QueryWriterRunner.Outcome = { _, _ in
        .failed("AiTerm can’t write queries here.", query: nil)
    }
    @ObservationIgnored var loadCompletions: @MainActor () async -> Void = {}
    @ObservationIgnored var checkReadiness: @MainActor () async -> Void = {}
    /// The clock and calendar a schedule's next runs are read on: the Mac's own, fixed by a rendering fixture.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var calendar = Calendar.autoupdatingCurrent
    /// Each kind's trigger as it was left when the person switched to the other, so switching back restores it.
    @ObservationIgnored private var parkedItemStart = SignalTrigger(source: .jira, query: "")
    @ObservationIgnored private var parkedSchedule = SignalTrigger(source: .schedule, query: "")
    @ObservationIgnored private var parkedQueryDone = SignalTrigger(source: .jira, query: "")
    @ObservationIgnored private var parkedOperatorDone = SignalTrigger(source: .operator, query: "")
    @ObservationIgnored private var parkedPersonDone = SignalTrigger(source: .person, query: "")
    /// Whether the person chose Done when themselves; until then a new signal's Done follows its Starts on.
    @ObservationIgnored private var doneChosen = false

    init(signal: Signal? = nil, kind: Signal.Kind = .operator, projects: [Project], context: SignalContext, seen: [SignalSeen] = [],
         at: Date = Date(),
         preview: @escaping @MainActor (SignalTrigger) async throws -> SignalRead = { _ in SignalRead(items: [], complete: true) },
         save: @escaping @MainActor (Signal) async throws -> Void) {
        self.original = signal; self.createdAt = signal?.createdAt ?? at; self.projects = projects; self.context = context; self.seen = seen
        self.readPreview = preview; self.save = save
        let kind = signal?.kind ?? kind
        self.kind = kind
        // A project signal runs one agent: the first row.
        let choices = signal?.agents ?? AgentCommand.workerAgents.map { AgentChoice(agent: $0, model: "", reasoning: nil) }
        draftRows = choices.map { AgentChoiceRow(choice: $0, initialDefault: signal == nil) }
        guard let signal else { return }
        name = signal.name; prompt = signal.work.prompt; start = signal.start; done = signal.done
        ticketDescription = signal.work.ticketDescription; requestDescription = signal.work.requestDescription
        then = signal.finish.then; mergeWhenReady = signal.finish.mergesWhenReady
        deleteMergedBranch = signal.finish.deletesMergedBranch
    }
    /// Whether the sheet edits a saved signal rather than making a new one.
    var isEditing: Bool { original != nil }
    /// Whether it starts ordinary tasks in their projects rather than handing them to the Operator.
    var isProject: Bool { kind == .project }

    /// Starts on: an item a query finds, or a schedule.
    enum StartKind: Hashable { case item, schedule }
    /// Done when: a query matches, or the Operator decides (an Operator signal) or you do (a project signal).
    enum DoneKind: Hashable { case query, operatorDecides, youDecide }
    var startKind: StartKind {
        get { start.source == .schedule ? .schedule : .item }
        set { setStartKind(newValue) }
    }
    var doneKind: DoneKind {
        get {
            switch done.source {
            case .operator: .operatorDecides
            case .person: .youDecide
            default: .query
            }
        }
        set { doneChosen = true; setDoneKind(newValue) }
    }
    /// The Done when choices its kind offers: a query, then who decides without one.
    var doneKinds: [DoneKind] { [.query, decides] }
    /// Who decides Done without a query: the Operator, or, on a project signal, you.
    private var decides: DoneKind { isProject ? .youDecide : .operatorDecides }
    var isScheduled: Bool { startKind == .schedule }
    private func setStartKind(_ kind: StartKind) {
        guard kind != startKind else { return }
        switch kind {
        case .schedule:
            parkedItemStart = start
            var schedule = parkedSchedule
            if schedule.project == nil, projects.count == 1 { schedule.project = projects[0].id }
            start = schedule
        case .item:
            parkedSchedule = start; start = parkedItemStart
        }
        // A new signal's Done follows: a schedule opens on The Operator decides (You decide on a project signal), an item
        // on A query matches.
        if !isEditing && !doneChosen { setDoneKind(kind == .schedule ? decides : .query) }
        // A run has no ticket for a Jira Done query.
        if kind == .schedule, done.source == .jira { done = SignalTrigger(source: .gitLab, description: done.description, query: "") }
    }
    private func setDoneKind(_ kind: DoneKind) {
        guard kind != doneKind, doneKinds.contains(kind) else { return }
        switch doneKind {
        case .query: parkedQueryDone = done
        case .operatorDecides: parkedOperatorDone = done
        case .youDecide: parkedPersonDone = done
        }
        switch kind {
        case .operatorDecides: done = parkedOperatorDone
        case .youDecide: done = parkedPersonDone
        case .query:
            var query = parkedQueryDone
            if isScheduled, query.source == .jira { query = SignalTrigger(source: .gitLab, description: query.description, query: "") }
            done = query
        }
    }
    /// A schedule's next four runs from now; none until its cron parses.
    var nextRuns: [Date] {
        guard let cron = start.cron else { return [] }
        var runs: [Date] = [], from = now()
        while runs.count < 4, let next = cron.next(after: from, in: calendar) { runs.append(next); from = next }
        return runs
    }
    /// The project a schedule's runs start in, once chosen.
    var scheduleProject: Project? { start.project.flatMap { id in projects.first { $0.id == id } } }
    /// "New Operator signal", "Edit project signal".
    var title: String { (isEditing ? "Edit " : "New ") + (isProject ? "project" : "Operator") + " signal" }
    /// The steps' names: a project signal's third step chooses its one agent.
    var stepNames: [String] {
        var names = Self.stepNames
        if isProject { names[Self.agentsStep - 1] = "Agent" }
        return names
    }
    var createLabel: String { isEditing ? "Save" : "Create Signal" }
    /// What the match preview reads: the Start trigger's source and query.
    var startKey: String { start.source.rawValue + "\n" + start.query }
    /// Why AiTerm will not run the typed Start or Done query, once there is one; Jira checks its own.
    var startRefusal: QueryRefusal? { refusal(of: start, start: true) }
    var doneRefusal: QueryRefusal? { refusal(of: done, start: false) }
    private func refusal(of trigger: SignalTrigger, start: Bool) -> QueryRefusal? {
        guard !trigger.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // A schedule's field says only what is wrong with its cron; Continue waits for its project as well.
        if trigger.source == .schedule { do { _ = try Cron(trigger.query); return nil } catch { return error } }
        return trigger.refusal(start: start)
    }
    /// Merge when ready is offered where the Start trigger's merge requests are the person's own, on an Operator signal.
    var offersMerge: Bool { !isProject && start.offersMerge }
    var finish: SignalFinish {
        SignalFinish(then: then, mergesWhenReady: offersMerge && mergeWhenReady,
                     deletesMergedBranch: then == .remove && deleteMergedBranch)
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
                                       ticketDescription: ticketDescription && !isScheduled, requestDescription: requestDescription && !isScheduled),
                      agents: agents, finish: finish, scheduledFrom: original?.scheduledFrom, kind: kind)
    }
    var offeredAgents: [AgentKind] { context.offeredAgents }
    func models(for agent: AgentKind) -> [AgentModel] { context.worker(agent)?.reading?.models ?? [] }
    var agents: [AgentChoice] { var found = Set<AgentChoice>(); return agentRows.map(\.choice).filter { found.insert($0).inserted } }

    /// Only an untouched default or an existing row's freshly verified effort needs resolving. A
    /// failed read leaves the saved row exactly as it was, even when the cached efforts differ.
    private func resolved(_ row: AgentChoiceRow) -> AgentChoiceRow {
        guard let worker = context.worker(row.choice.agent) else { return row }
        var row = row
        if row.choice.model.isEmpty {
            row.choice = worker.choice
        } else if let reading = worker.reading, reading.failure == nil, !worker.refreshing,
                  original?.agents.contains(row.choice) == true,
                  let model = reading.models.first(where: { $0.id == row.choice.model }) {
            var preference = ModelPreference(model: row.choice.model, reasoning: row.choice.reasoning)
            preference.select(model)
            row.choice.reasoning = preference.reasoning
        }
        return row
    }

    var agentsWhyNot: String? {
        guard !agentRows.isEmpty else { return isProject ? "Install an agent in Settings › Agents." : "Add an agent." }
        for row in agentRows {
            let choice = row.choice
            guard let worker = context.worker(choice.agent) else {
                return "\(choice.agent.displayName) isn’t installed. " + (isProject ? "Choose another agent." : "Choose another agent for its row, or remove it.")
            }
            if worker.reading == nil || worker.reading?.failure != nil,
               !choice.model.isEmpty, original?.agents.contains(choice) == true { continue }
            guard let model = worker.reading?.models.first(where: { $0.id == choice.model }),
                  choice.reasoning.map(model.efforts.contains) ?? true else {
                return worker.help ?? ModelReasoningFields.unavailableHelp
            }
        }
        return nil
    }
    func addAgent() {
        guard !isProject || agentRows.isEmpty,
              let agent = offeredAgents.first(where: { agent in !draftRows.contains { $0.choice.agent == agent } }) ?? offeredAgents.first else { return }
        draftRows.append(AgentChoiceRow(choice: AgentChoice(agent: agent, model: "", reasoning: nil)))
    }
    func removeAgent(_ id: UUID) { draftRows.removeAll { $0.id == id } }
    func setAgent(_ agent: AgentKind, of id: UUID) {
        guard offeredAgents.contains(agent), let index = draftRows.firstIndex(where: { $0.id == id }),
              draftRows[index].choice.agent != agent else { return }
        draftRows[index].initialDefault = false
        draftRows[index].choice = AgentChoice(agent: agent, model: "", reasoning: nil)
    }
    func setModel(_ model: AgentModel, of id: UUID) {
        guard let index = draftRows.firstIndex(where: { $0.id == id }) else { return }
        let choice = resolved(draftRows[index]).choice
        guard models(for: choice.agent).contains(model) else { return }
        var preference = ModelPreference(model: choice.model, reasoning: choice.reasoning)
        preference.select(model)
        draftRows[index].initialDefault = false
        draftRows[index].choice = AgentChoice(agent: choice.agent, model: preference.model, reasoning: preference.reasoning)
    }
    func setReasoning(_ reasoning: String?, of id: UUID) {
        guard let index = draftRows.firstIndex(where: { $0.id == id }) else { return }
        var choice = resolved(draftRows[index]).choice
        choice.reasoning = reasoning
        draftRows[index].initialDefault = false
        draftRows[index].choice = choice
    }
    func canAdvance(step: Int) -> Bool {
        guard !starting, TaskCreator.isNamed(name) else { return false }
        if step == Self.nameStep { return true }
        guard start.isValid(start: true) else { return false }
        if step == Self.startStep { return true }
        guard agentsWhyNot == nil else { return false }
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
        // A schedule reads nothing: its next runs come from its cron.
        guard expected.source.readsItems else { return }
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
        if trigger.source == .operator || trigger.source == .person { return false }
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
