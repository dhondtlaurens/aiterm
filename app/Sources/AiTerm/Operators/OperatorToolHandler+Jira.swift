import Foundation
import AiTermCore

/// The Jira slice (spec §5): `jira_create`, `jira_move` and `jira_link`, and the filing of off-brief finds. A
/// write is refused unless the broadcast's frozen slice allows it, and is kept to the broadcast's Jira
/// projects. Comments are not here: a comment messages people.
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
        let jira = try connectedJira()
        // Another call with this key is creating now: this one would make the ticket twice.
        let flight = "\(run.id.uuidString)/create/\(callKey)"
        guard filingFinds.insert(flight).inserted else { throw ToolRefusal("jira_create with this key is still running: call it again for its ticket.") }
        defer { filingFinds.remove(flight) }
        let key = try await jira.createIssue(project: projectKey, type: type, summary: summary, description: description, parent: parent)
        mutate(in: run.id) { $0.updateRun(id: run.id) { $0.jiraCreated[callKey] = key } }
        return ["key": .string(key), "created": true]
    }

    func jiraMove(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try inScope(ticket: try call.string("key"), of: run), status = try call.string("status")
        try requireSlice(in: run, otherwise: "Move \(key) to \(status)")
        let moved = try await connectedJira().transition(key: key, to: status)
        return moved ? ["key": .string(key), "status": .string(status), "moved": true]
                     : ["key": .string(key), "status": .string(status), "moved": false, "note": .string("\(key) is already in \(status).")]
    }

    func jiraLink(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try inScope(ticket: try call.string("key"), of: run), other = try inScope(ticket: try call.string("to"), of: run)
        let type = try call.string("type")
        try requireSlice(in: run, otherwise: "Link \(key) to \(other) (\(type))")
        try await connectedJira().link(key: key, to: other, type: type)
        return ["key": .string(key), "to": .string(other), "type": .string(type), "linked": true]
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
        guard let jira = ports.jira() else { return .notFiled(Self.notConnected) }
        // Another call is filing this find now: it is that call's to say.
        guard filingFinds.insert("\(runId.uuidString)/\(key)").inserted else { return .notAttempted }
        defer { filingFinds.remove("\(runId.uuidString)/\(key)") }
        do {
            let ticket = try await jira.createIssue(project: project, type: "Task", summary: find.title, description: find.why, parent: nil)
            mutate(in: runId) { state in
                state.updateRun(id: runId) { run in
                    if let index = run.finds.firstIndex(where: { $0.key == key }) { run.finds[index].ticket = ticket }
                }
            }
            return .filed(ticket)
        } catch {
            return .notFiled(error.localizedDescription)
        }
    }

    /// How a refusal that says "AiTerm noted it for the debrief" ends once the find was filed, or was not.
    static func ending(_ filing: Filing) -> String {
        switch filing {
        case .filed(let ticket): return " and filed it as \(ticket)."
        case .notFiled(let reason): return ". It could not be filed: \(reason)"
        case .notAttempted: return "."
        }
    }
}
