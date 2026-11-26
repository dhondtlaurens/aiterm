import Foundation

extension UpdateScript {
    /// 2.0.0: the workspace saves every field it has, and reads nothing it does not write.
    ///
    /// 1.5.0 left a value out while it was the default, and read it back as that default, so files
    /// saved before the field existed read the same way. It also kept what it did not know: keys,
    /// agents and kinds an earlier or a later build wrote. This step writes each default out, drops
    /// what 2.0.0 does not read, and moves a task of a retired agent (Grok) to Claude on Claude's
    /// defaults, as 1.5.0 showed it.
    static let update2_0_0 = UpdateScript(
        version: ReleaseVersion(major: 2, minor: 0, patch: 0),
        summary: "Writes every default out, renames the Oracle's unanswered rounds, drops retired keys and agents."
    ) { context in
        var state = context.state
        // Dividers between signals (`signalDividers`) are retired; `projects` is the list before `items`.
        state["signalDividers"] = nil
        state["projects"] = nil
        for key in ["items", "tasks", "terminals", "archive", "signals", "signalSeen", "scheduleCursors", "operatorFolded"] {
            state.fill(key, with: [])
        }
        state.fill("operatorOpen", with: false)
        // Saved as flat lists, a key then its value.
        state.edit("lastAgentByProject") { $0 = Update2_0_0.pairs($0) { _, agent in Update2_0_0.isAgent(agent) } }
        state.edit("lastModelByAgent") { $0 = Update2_0_0.pairs($0) { agent, _ in Update2_0_0.isAgent(agent) } }
        state.edit("tasks") { $0.editEach(Update2_0_0.task) }
        state.edit("archive") { $0.editEach { $0.edit("task", Update2_0_0.task) } }
        state.edit("signals") { $0.editEach(Update2_0_0.signal) }
        state.edit("operatorSession") { session in
            session.edit("oracleRounds") { rounds in
                rounds.editEach { round in
                    if round["stage"] == "unchallenged" { round["stage"] = "unanswered" }
                    if let reason = round["unchallengedReason"] {
                        round["unchallengedReason"] = nil
                        round["unansweredReason"] = reason
                    }
                }
            }
        }
        context.state = state
    }
}

/// The pieces of `UpdateScript.update2_0_0`.
enum Update2_0_0 {
    static let agents: Set<String> = ["claude", "codex", "pi"]

    static func isAgent(_ value: JSONValue) -> Bool { value.stringValue.map(agents.contains) ?? false }

    /// A flat `[key, value, key, value…]` list with the pairs `keep` refuses dropped.
    static func pairs(_ list: JSONValue, keep: (JSONValue, JSONValue) -> Bool) -> JSONValue {
        guard let elements = list.arrayValue else { return list }
        var kept: [JSONValue] = []
        for index in stride(from: 0, to: elements.count - 1, by: 2) where keep(elements[index], elements[index + 1]) {
            kept += [elements[index], elements[index + 1]]
        }
        return .array(kept)
    }

    static func task(_ task: inout JSONValue) {
        task.fill("kind", with: "task")
        task.fill("takenOver", with: false)
        task.fill("conversations", with: [])
        if !isAgent(task["agent"] ?? .null) {
            task["agent"] = "claude"
            task["model"] = ""
            task["reasoning"] = nil
        }
        // A conversation of an agent 2.0.0 does not know, or with an id no resume can use, was never resumed.
        task.edit("conversations") { conversations in
            guard let list = conversations.arrayValue else { conversations = []; return }
            conversations = .array(list.filter { conversation in
                guard isAgent(conversation["agent"] ?? .null), let id = conversation["id"]?.stringValue else { return false }
                return TaskConversation.isResumable(id)
            })
        }
        task.edit("jira") { $0.fill("source", with: ["jira": [:]]) }
        task.edit("signalTask") { record in
            record.edit("current") { $0.edit("configuration", signal) }
            record.edit("pendingStages") { $0.editEach { $0.edit("configuration", signal) } }
            record.edit("previousStage") { $0.edit("stage") { $0.edit("configuration", signal) } }
        }
    }

    /// A signal, or a stage's copy of one: one saved without a kind is an Operator signal.
    static func signal(_ signal: inout JSONValue) {
        signal.fill("kind", with: "operator")
    }
}
