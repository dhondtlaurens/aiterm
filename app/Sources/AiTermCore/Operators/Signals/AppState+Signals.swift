import Foundation

public extension AppState {
    var operatorWorkTasks: [TaskItem] { allSignalTasks.filter { $0.signalTask?.keepsOperatorSession == true } }
    /// The contract also permits an explicit question about the workload/settings as a whole.
    /// It remains real work until answered, even when it has no task UUID.
    var operatorHasWork: Bool {
        !operatorWorkTasks.isEmpty || operatorSession?.questions.contains { $0.task == nil && $0.resolvedAt == nil } == true
    }

    /// A completed or superseded stage cannot leave a question badge or notification behind.
    func isCurrentOperatorQuestion(_ question: OperatorSession.Question) -> Bool {
        guard let id = question.task else { return true }
        guard let record = signalItem(id: id)?.signalTask,
              question.stage.map({ $0 == record.stage }) != false,
              question.ownership.map({ $0 == record.ownership }) != false else { return false }
        switch record.phase {
        case .launching, .choosing, .working, .watching, .blocked: return true
        case .done, .archived, .unknown: return false
        }
    }
    var currentOperatorQuestions: [OperatorSession.Question] {
        (operatorSession?.questions ?? []).filter { $0.resolvedAt == nil && isCurrentOperatorQuestion($0) }
    }

    /// Backpack Mode must bridge quiet turns while sources or retained stages can schedule work.
    var operatorMayStartWork: Bool {
        guard operatorSession?.paused != true else { return false }
        if signals.contains(where: \.isRunnable) { return true }
        return allSignalTasks.contains { task in
            guard let record = task.signalTask,
                  signal(id: record.current.signal)?.enabled != false, record.current.configuration.isRunnable else { return false }
            switch record.phase {
            case .launching, .choosing, .working, .watching, .blocked: return true
            case .done: return record.thenApplied != true || !record.pendingStages.isEmpty
            case .archived: return !record.pendingStages.isEmpty
            case .unknown: return false
            }
        }
    }
    /// A person's Take Over of sidebar task `id`: its signal record goes and the task is marked `takenOver`, so it is
    /// an ordinary task of its project, which opens, and no later match continues it. The Operator's questions about
    /// it and its paused workers go with the record. The record removed, or nil when the task has none and nothing changed.
    @discardableResult
    mutating func takeOver(_ id: UUID) -> SignalTask? {
        guard let index = tasks.firstIndex(where: { $0.id == id }), let record = tasks[index].signalTask else { return nil }
        tasks[index].signalTask = nil
        tasks[index].takenOver = true
        updateProject(id: tasks[index].projectId) { $0.collapsed = false }
        operatorSession?.questions.removeAll { $0.task == id }
        operatorSession?.pausedWorkers?.removeAll { $0.task == id }
        return record
    }
    func signal(id: UUID) -> Signal? { signals.first { $0.id == id } }
    var allSignalTasks: [TaskItem] { tasks.filter { $0.isUnderOperator } + archive.map(\.task).filter { $0.isUnderOperator } }
    func signalItem(id: UUID) -> TaskItem? { task(id: id) ?? archived(id: id)?.task }
    mutating func updateSignalItem(_ id: UUID, _ change: (inout TaskItem) throws -> Void) rethrows {
        if let index = tasks.firstIndex(where: { $0.id == id }) { try change(&tasks[index]) }
        else if let index = archive.firstIndex(where: { $0.id == id }) { try change(&archive[index].task) }
    }
    mutating func updateSignalTask(_ id: UUID, _ change: (inout SignalTask) throws -> Void) rethrows {
        try updateSignalItem(id) { task in
            guard var record = task.signalTask else { return }
            try change(&record); task.signalTask = record
        }
    }

    /// The Operator's retention, as of `at`: seen items no live stage still names, resolved worker
    /// questions and the Oracle rounds of `answer_worker`, `choose_agent` and `open_tab` whose task is
    /// gone or whose stage or ownership moved on, the session's own bounds, and the source failures
    /// of signals that no longer exist.
    mutating func pruneOperator(at: Date) {
        let records = Dictionary(allSignalTasks.compactMap { task in task.signalTask.map { (task.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let activeSignals = Set(signals.map(\.id))
        let liveItems = Set(records.values.flatMap { record in
            ([record.current.item] + record.pendingStages.map(\.item) + (record.watchedRequest.map { [ItemRef.mergeRequest($0)] } ?? [])).compactMap(\.identity)
        })
        signalSeen = SignalSeen.pruned(signalSeen, liveItems: liveItems, now: at)
        scheduleCursors = scheduleCursors.filter { activeSignals.contains($0.key) }
        operatorSession?.questions.removeAll { question in
            guard question.resolvedAt != nil, question.workerQuestion != nil, let id = question.task else { return false }
            guard let record = records[id] else { return true }
            return question.stage != record.stage || question.ownership != record.ownership
        }
        operatorSession?.oracleRounds.removeAll { round in
            guard [OperatorTool.answerWorker, .chooseAgent, .openTab, .finishStage].map(\.rawValue).contains(round.tool), let evidence = round.askedEvidence,
                  let binding = try? JSONDecoder().decode(JSONValue.self, from: Data(evidence.utf8)),
                  let id = binding["task"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return false }
            guard let record = records[id] else { return true }
            return binding["stage"]?.intValue != record.stage || binding["ownership"]?.intValue != record.ownership
        }
        operatorSession?.prune(at: at)
        if let failures = operatorSession?.sourceFailures {
            let kept = failures.filter { UUID(uuidString: $0.key).map(activeSignals.contains) == true }
            operatorSession?.sourceFailures = kept.isEmpty ? nil : kept
        }
    }
    /// Resolves, as of `at`, every open Operator question that is no longer current: its stage
    /// finished or was superseded. Whether any question changed.
    @discardableResult
    mutating func withdrawObsoleteQuestions(at: Date) -> Bool {
        let obsolete = Set((operatorSession?.questions ?? []).filter {
            $0.resolvedAt == nil && !isCurrentOperatorQuestion($0)
        }.map(\.id))
        guard !obsolete.isEmpty else { return false }
        for index in operatorSession?.questions.indices ?? 0..<0 {
            if let id = operatorSession?.questions[index].id, obsolete.contains(id) {
                operatorSession?.questions[index].resolvedAt = at
            }
        }
        return true
    }
}
