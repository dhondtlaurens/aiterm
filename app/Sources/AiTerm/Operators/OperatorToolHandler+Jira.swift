import Foundation
import CryptoKit
import AiTermCore

/// The Jira slice (spec §5): `jira_create`, `jira_move`, `jira_link` and `jira_sprint`, and the filing of off-brief finds. A
/// write is refused unless the broadcast's frozen slice allows it, and is kept to the broadcast's Jira
/// projects. Each is read fresh right before it is sent, after any read that came first: none goes while the
/// operation is paused, offline or ended. Comments are not here: a comment messages people. `jira_board` only reads
/// (spec §L), so it needs no slice.
extension OperatorToolHandler {
    private static let sliceOff = "The Jira slice is off for this broadcast."
    private static let notConnected = "Jira isn’t connected in AiTerm’s Settings › Integrations."

    func jiraCreate(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let callKey = try call.string("key")
        // The same key again is the same ticket: what the first call made, and nothing more.
        if let made = run.jiraCreated[callKey] { return ["key": .string(made), "created": false] }
        let project = try call.string("project"), type = try call.string("type")
        let summary = try call.string("summary"), description = try call.string("description")
        let projectKey = try inScope(project: project, of: run)
        let parent = try call.optionalString("parent").map { try inScope(ticket: $0, of: run) }
        try requireSlice(in: run, otherwise: "Create the Jira ticket “\(summary)” in \(projectKey)")
        try jiraWritable(run.id)
        let jira = try connectedJira()
        // Another call with this key is creating now: this one would make the ticket twice.
        let flight = "\(run.id.uuidString)/create/\(callKey)"
        guard filingFinds.insert(flight).inserted else { throw ToolRefusal("jira_create with this key is still running: call it again for its ticket.") }
        defer { filingFinds.remove(flight) }
        // The ticket carries the call's label: a create whose answer was lost is found by it, not made again.
        let label = Self.createLabel(run: run.id, key: callKey), pending = "jira_create_v2/\(callKey)"
        if state.run(id: run.id)?.pendingWrites.contains("jira_create/\(callKey)") == true {
            throw ToolRefusal("This pending create used an older Jira label that cannot identify its ticket safely. Reconcile it manually in Jira and the saved broadcast before continuing; AiTerm kept the pending marker and sent nothing.")
        }
        if state.run(id: run.id)?.pendingWrites.contains(pending) == true {
            // The key still identifies the original write if retry arguments name another allowed project.
            let projects = run.jiraProjectKeys.map { JiraProjectRef(id: $0, key: $0, name: $0, siteURL: jira.siteURL) }
            let matches = try await jira.search(jql: "labels = \"\(label)\"", in: projects)
            guard matches.count <= 1 else {
                throw ToolRefusal("More than one Jira ticket has this create's label. Reconcile them manually before continuing; AiTerm kept the pending marker and sent nothing.")
            }
            if let made = matches.first {
                settle(pending, in: run.id) { $0.jiraCreated[callKey] = made.key }
                return ["key": .string(made.key), "created": false, "note": "The first call made it; its answer was lost."]
            }
        }
        // Read fresh after the look, right before the write.
        try jiraWritable(run.id)
        try markPending(pending, in: run.id)
        let key: String
        do { key = try await jira.createIssue(project: projectKey, type: type, summary: summary, description: description, parent: parent, labels: [label]) }
        catch {
            if !Self.mayHaveLanded(error) { settle(pending, in: run.id) }
            throw error
        }
        settle(pending, in: run.id) { $0.jiraCreated[callKey] = key }
        return ["key": .string(key), "created": true]
    }

    /// Bounded, Jira-safe identity for the complete run and key. NFC matches Swift String equality,
    /// so a canonically equivalent retry searches the same label as its persisted pending marker.
    static func createLabel(run: UUID, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "aiterm-v2-\(run.uuidString.lowercased())-\(digest)"
    }

    /// Jira writes go while the operation plans (its tickets for planned work) or runs, read fresh: never while you
    /// paused or ended it, its Operator is offline, or its slice is off.
    func jiraWritable(_ runId: UUID) throws(ToolRefusal) {
        guard let run = state.run(id: runId) else { throw ToolRefusal("This broadcast is no longer in AiTerm.") }
        guard run.profile.slices.jira else { throw ToolRefusal(Self.sliceOff) }
        if run.state == .planning, run.intent == nil { return }
        try acceptsWork(run)
    }

    func jiraMove(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try inScope(ticket: try call.string("key"), of: run), status = try call.string("status")
        try requireSlice(in: run, otherwise: "Move \(key) to \(status)")
        try jiraWritable(run.id)
        let runId = run.id
        // Jira's status and transitions are read first: the move is checked again after them.
        let moved = try await connectedJira().transition(key: key, to: status, beforeWrite: { @MainActor [weak self] in
            guard let self else { throw ToolRefusal("AiTerm is closing; nothing more is written.") }
            try self.jiraWritable(runId)
        })
        return moved ? ["key": .string(key), "status": .string(status), "moved": true]
                     : ["key": .string(key), "status": .string(status), "moved": false, "note": .string("\(key) is already in \(status).")]
    }

    func jiraLink(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try inScope(ticket: try call.string("key"), of: run), other = try inScope(ticket: try call.string("to"), of: run)
        let type = try call.string("type")
        try requireSlice(in: run, otherwise: "Link \(key) to \(other) (\(type))")
        let jira = try connectedJira()
        try jiraWritable(run.id)
        try await jira.link(key: key, to: other, type: type)
        return ["key": .string(key), "to": .string(other), "type": .string(type), "linked": true]
    }

    /// Where `jira_sprint` puts its tickets.
    private enum SprintTarget: Equatable {
        case sprint(Int), backlog
        /// What the call records for its key, and answers.
        var label: String { if case .sprint(let id) = self { String(id) } else { "backlog" } }
    }

    /// For each of the broadcast's Jira projects, its boards: the active and future sprints of each board that has any, and the columns
    /// with the statuses in them (spec §L). A read, so it needs no slice, and Jira's answer is awaited for the search's budget.
    func jiraBoard(in run: OperatorRun) async throws -> JSONValue {
        let jira = try connectedJira()
        var projects: [String] = []
        for key in run.jiraProjectKeys.map({ $0.uppercased() }) where !projects.contains(key) { projects.append(key) }
        guard !projects.isEmpty else { throw outOfScope("", of: run) }
        let budget = ports.jiraSearchBudget
        switch await Self.within(budget, { try await Self.readBoards(of: projects, with: jira) }) {
        case .success(let answer): return answer
        case .failure(let error) where error is NoAnswer:
            throw ToolRefusal("Jira didn’t answer within \(Int(budget.components.seconds)) s; call jira_board again.")
        case .failure(let error): throw error
        }
    }

    private static func readBoards(of projects: [String], with jira: any OperatorJira) async throws -> JSONValue {
        var answer: [JSONValue] = []
        for project in projects {
            var boards: [JSONValue] = []
            for board in try await jira.boards(project: project) {
                let sprints = try await Self.sprints(of: board, with: jira)
                let columns = try await jira.columns(board: board.id)
                boards.append(["id": .int(board.id), "name": .string(board.name), "type": .string(board.type),
                               "sprints": .array(sprints.map { sprint in
                                   ["id": .int(sprint.id), "name": .string(sprint.name), "state": .string(sprint.state),
                                    "startDate": sprint.startDate.map(JSONValue.string) ?? .null, "endDate": sprint.endDate.map(JSONValue.string) ?? .null]
                               }),
                               "columns": .array(columns.map { ["name": .string($0.name), "statuses": .array($0.statuses.map(JSONValue.string))] })])
            }
            answer.append(["project": .string(project), "boards": .array(boards)])
        }
        return .array(answer)
    }

    /// Puts tickets of the broadcast's Jira projects in an active or future sprint on a board of those projects, or back on
    /// the backlog (spec §L). The same key again moves nothing: adding to a sprint is safe to repeat, so no write is marked pending.
    func jiraSprint(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let callKey = try call.string("key")
        if let done = run.jiraSprinted[callKey] {
            return ["sprint": .string(done), "sprinted": false, "note": "The first call with this key already did it."]
        }
        guard let named = call.arguments["tickets"]?.arrayValue, !named.isEmpty else { throw ToolRefusal("jira_sprint needs `tickets`, the keys to move.") }
        var tickets: [String] = []
        for value in named {
            guard let text = value.stringValue else { throw ToolRefusal("jira_sprint’s `tickets` are ticket keys like PLUTO-231.") }
            let key = try inScope(ticket: text, of: run)
            if !tickets.contains(key) { tickets.append(key) }
        }
        let target = try sprintTarget(call)
        let list = tickets.joined(separator: ", ")
        switch target {
        case .sprint(let id): try requireSlice(in: run, otherwise: "Put \(list) in sprint \(id)")
        case .backlog: try requireSlice(in: run, otherwise: "Move \(list) to the backlog")
        }
        try jiraWritable(run.id)
        let jira = try connectedJira()
        let runId = run.id, projects = run.jiraProjectKeys, moved = tickets
        let budget = ports.jiraSearchBudget
        // Jira's boards and sprints are read first: the move is checked again after them, right before it is sent.
        let outcome = await Self.within(budget) { [self] in
            if case .sprint(let id) = target {
                guard try await Self.sprintIsOnABoard(id, of: projects, with: jira) else {
                    throw ToolRefusal("Sprint \(id) isn’t an active or future sprint on a board of this broadcast’s Jira projects: \(projects.joined(separator: ", ")).")
                }
            }
            let check: @Sendable () async throws -> Void = { @MainActor [weak self] in
                guard let self else { throw ToolRefusal("AiTerm is closing; nothing more is written.") }
                try self.jiraWritable(runId)
            }
            switch target {
            case .sprint(let id): try await jira.addToSprint(id, tickets: moved, beforeWrite: check)
            case .backlog: try await jira.moveToBacklog(tickets: moved, beforeWrite: check)
            }
            mutate(in: runId) { $0.updateRun(id: runId) { $0.jiraSprinted[callKey] = target.label } }
            _ = workspace.flush()
        }
        switch outcome {
        case .success: return ["sprint": .string(target.label), "tickets": .array(tickets.map(JSONValue.string)), "sprinted": true]
        case .failure(let error) where error is NoAnswer:
            throw ToolRefusal("Jira didn’t answer within \(Int(budget.components.seconds)) s, so the tickets may or may not have moved; call jira_sprint again with the same key, which is safe to repeat.")
        case .failure(let error): throw error
        }
    }

    /// `sprint` as a sprint’s id or `backlog`.
    private func sprintTarget(_ call: ToolCall) throws(ToolRefusal) -> SprintTarget {
        guard let value = call.arguments["sprint"], value != .null else { throw ToolRefusal("jira_sprint needs `sprint`.") }
        let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if text?.lowercased() == "backlog" { return .backlog }
        if let id = value.intValue ?? text.flatMap({ Int($0) }), id > 0 { return .sprint(id) }
        throw ToolRefusal("jira_sprint’s `sprint` is a sprint’s id from jira_board, or \"backlog\".")
    }

    /// The active and future sprints of `board`: none for a kanban board, and none for one Jira says has no sprints (its 400).
    /// A team-managed scrum board is `simple`, not `scrum`, so only `kanban` is skipped by its type.
    private static func sprints(of board: JiraBoard, with jira: any OperatorJira) async throws -> [JiraSprint] {
        guard board.type != "kanban" else { return [] }
        do { return try await jira.sprints(board: board.id) }
        catch JiraError.badResponse(400) { return [] }
    }

    /// Whether `id` is an active or future sprint of a board of one of `projects`.
    private static func sprintIsOnABoard(_ id: Int, of projects: [String], with jira: any OperatorJira) async throws -> Bool {
        for project in projects {
            for board in try await jira.boards(project: project) {
                if try await sprints(of: board, with: jira).contains(where: { $0.id == id }) { return true }
            }
        }
        return false
    }

    /// Refuses a write the Jira slice does not allow, and leaves `otherwise` (what was not done) for the person once.
    private func requireSlice(in run: OperatorRun, otherwise left: String) throws(ToolRefusal) {
        guard !run.profile.slices.jira else { return }
        let sentence = "\(left): the Jira slice is off."
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) { if !$0.leftForYou.contains(sentence) { $0.leftForYou.append(sentence) } }
        }
        throw ToolRefusal(Self.sliceOff)
    }

    private func connectedJira() throws(ToolRefusal) -> any OperatorJira {
        guard let jira = ports.jira() else { throw ToolRefusal(Self.notConnected) }
        return jira
    }

    private func inScope(project: String, of run: OperatorRun) throws(ToolRefusal) -> String {
        let key = project.uppercased()
        guard run.jiraProjectKeys.contains(where: { $0.uppercased() == key }) else { throw outOfScope(key, of: run) }
        return key
    }

    /// `ticket` as an upper-case key, when its project is one of the broadcast's.
    private func inScope(ticket: String, of run: OperatorRun) throws(ToolRefusal) -> String {
        let key = ticket.uppercased()
        guard key.range(of: #"^[A-Z][A-Z0-9_]+-[0-9]+$"#, options: .regularExpression) != nil, let dash = key.lastIndex(of: "-") else {
            throw ToolRefusal("\(ticket) isn’t a Jira ticket key like PLUTO-231.")
        }
        guard run.jiraProjectKeys.contains(where: { $0.uppercased() == String(key[..<dash]) }) else { throw outOfScope(key, of: run) }
        return key
    }

    private func outOfScope(_ what: String, of run: OperatorRun) -> ToolRefusal {
        run.jiraProjectKeys.isEmpty
            ? ToolRefusal("This broadcast has no Jira projects.")
            : ToolRefusal("\(what) isn’t in this broadcast’s Jira projects: \(run.jiraProjectKeys.joined(separator: ", ")).")
    }

    // -- finds ----------------------------------------------------------------------------------

    /// What filing a find came to.
    enum Filing: Equatable {
        case filed(String), notFiled(String), notAttempted
    }

    /// With the Jira slice on, files the find `key` as a Task in the broadcast's first Jira project (its title the
    /// summary, why the description) and keeps the ticket on the find. A find already filed is not filed again;
    /// one whose filing failed is tried again. A failed filing leaves the find as it was.
    func fileFind(key: String, in runId: UUID) async -> Filing {
        guard let run = state.run(id: runId), run.profile.slices.jira, let find = run.finds.first(where: { $0.key == key }) else { return .notAttempted }
        if let ticket = find.ticket { return .filed(ticket) }
        guard let project = run.jiraProjectKeys.first else { return .notFiled("This broadcast has no Jira project to file it in.") }
        guard ports.jira() != nil else { return .notFiled(Self.notConnected) }
        // Another call is filing this find now: it is that call's to say.
        guard filingFinds.insert("\(runId.uuidString)/\(key)").inserted else { return .notAttempted }
        defer { filingFinds.remove("\(runId.uuidString)/\(key)") }
        do {
            try jiraWritable(runId)
            // Finds and explicit jira_create calls have separate idempotency keys.
            let call = ToolCall(tool: "jira_create", arguments: ["key": .string("find/" + key), "project": .string(project),
                "type": "Task", "summary": .string(find.title), "description": .string(find.why)])
            let answer = try await jiraCreate(call, in: run)
            guard let ticket = answer["key"]?.stringValue else { return .notFiled("Jira returned no ticket key.") }
            mutate(in: runId) { state in
                state.updateRun(id: runId) { run in
                    if let index = run.finds.firstIndex(where: { $0.key == key }) { run.finds[index].ticket = ticket }
                }
            }
            _ = workspace.flush()
            return .filed(ticket)
        } catch let refusal as ToolRefusal {
            return .notFiled(refusal.message)
        } catch {
            return .notFiled(error.localizedDescription)
        }
    }

    /// How a refusal that says "AiTerm noted it for the summary" ends once the find was filed, or was not.
    static func ending(_ filing: Filing) -> String {
        switch filing {
        case .filed(let ticket): return " and filed it as \(ticket)."
        case .notFiled(let reason): return ". It could not be filed: \(reason)"
        case .notAttempted: return "."
        }
    }
}
