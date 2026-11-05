import Foundation
import AiTermCore

extension OperatorToolHandler {
    /// `update_request`: changes the title, description or assignee of the request `finish_task` opened for a task, so the
    /// Operator corrects it through AiTerm rather than the host's CLI, which its shell is refused. It merges nothing and
    /// marks nothing ready, so it needs no slice and the Oracle isn't asked; it is refused once the broadcast is paused or
    /// ended, the task taken over, its origin moved to another repository, or the request is no longer open. Each change
    /// is the same however often it is made.
    func updateRequest(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run)
        let edit = RequestContent(title: Self.said(call.optionalString("title")), description: Self.said(call.optionalString("description")),
                                  assignee: Self.said(call.optionalString("assignee")))
        guard !edit.isEmpty else { throw ToolRefusal("Give the title, description or assignee to change.") }
        let operated = try notTakenOver(task)
        try acceptsWork(run)
        guard let publication = operated.publication, let number = publication.mergeRequestNumber else {
            throw ToolRefusal("\(operated.key) has no merge request yet: finish_task opens it, with the title, description and assignee you give it.")
        }
        let reference = publication.mergeRequestURL.map { CodeHost(webURL: $0).reference(number) } ?? "#\(number)"
        if publication.merged { throw ToolRefusal("\(reference) is merged: AiTerm changes only an open one.") }
        let host = try await reviewHost(of: task, request: publication)
        // A new assignee is saved as the Operator's before the host is asked: a request still to be assigned (its first
        // assignment failed) is then assigned to them, never to an older choice, however the write below ends.
        if let assignee = edit.assignee {
            // A publication assigning the request now read the older choice: it would write it after this one. Read with
            // the save below in one step, so one that starts after reads the new choice.
            if state.task(id: task.id)?.operated?.publication?.assigning == true, publishing(task.id) {
                throw ToolRefusal("AiTerm is assigning \(reference) now, from finish_task: call update_request again once it answers.")
            }
            mutate(in: run.id) { state in
                state.updateOperated(task.id) {
                    guard $0.publication != nil else { return }
                    var requested = $0.publication?.requested ?? RequestContent()
                    requested.assignee = assignee
                    $0.publication?.requested = requested
                }
            }
            guard workspace.flush() else {
                throw ToolRefusal("AiTerm couldn’t save the new assignee, so it changed nothing. Try again once the workspace saves.")
            }
        }
        let check = writeCheck(task, number: number, in: run.id, review: false)
        try await host.updateRequest(number, edit, beforeWrite: { live in
            guard ["opened", "open"].contains(live.state) else {
                throw ToolRefusal("\(reference) is \(live.state): AiTerm changes only an open one.")
            }
            try await check()
        })
        if let assignee = edit.assignee {
            mutate(in: run.id) { state in
                state.updateOperated(task.id) {
                    $0.publication?.assignee = assignee
                    $0.publication?.assigning = nil
                }
            }
            // Unsaved, the request is still to be assigned, to this same assignee: assigning again changes nothing.
            _ = workspace.flush()
        }
        let changed = [edit.title.map { _ in "title" }, edit.description.map { _ in "description" }, edit.assignee.map { _ in "assignee" }]
        return ["task": .string(operated.key), "mergeRequest": publication.mergeRequestURL.map(JSONValue.string) ?? .null,
                "updated": .array(changed.compactMap { $0 }.map(JSONValue.string))]
    }

    /// `retry_pipeline`: reruns the failed pipeline of the task's own open request (snag G: six pipelines failed on runner
    /// timeouts and image pulls, and the shell gate refuses the host's API). It changes no code, so it needs no slice and the
    /// Oracle isn't asked. It is refused once the broadcast is paused or ended, the task taken over, its origin moved to
    /// another repository, for a request merged or not open on the host, one not from the task's own branch, and a pipeline
    /// that didn't fail; each is read fresh right before the retry. A repeat finds the pipeline running and retries nothing.
    func retryPipeline(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run)
        let operated = try notTakenOver(task)
        try acceptsWork(run)
        guard let publication = operated.publication, let number = publication.mergeRequestNumber else {
            throw ToolRefusal("\(operated.key) has no merge request yet: finish_task opens it.")
        }
        let reference = publication.mergeRequestURL.map { CodeHost(webURL: $0).reference(number) } ?? "#\(number)"
        if publication.merged || publication.mergedSHA != nil { throw ToolRefusal("\(reference) is merged: there is no pipeline of it to retry.") }
        // Two calls at once would both find it failed and retry it twice.
        let flight = WriteInFlight(kind: .pipelineRetry, run: run.id, key: task.id.uuidString)
        guard writesInFlight.insert(flight).inserted else {
            throw ToolRefusal("AiTerm is retrying \(reference)’s pipeline now: call retry_pipeline again for what it found.")
        }
        defer { writesInFlight.remove(flight) }
        let host = try await reviewHost(of: task, request: publication)
        let check = writeCheck(task, number: number, in: run.id, review: false)
        let key = operated.key, branch = task.branch
        let result: PipelineRetry
        do {
            result = try await host.retryPipeline(number, beforeWrite: { live in
                guard ["opened", "open"].contains(live.state) else {
                    throw ToolRefusal("\(reference) is \(live.state): AiTerm retries only an open request’s pipeline.")
                }
                guard live.forkHead == nil, live.sourceBranch == branch else {
                    throw ToolRefusal("\(reference) isn’t \(key)’s request on the host: it is from \(live.forkHead ?? live.sourceBranch), not \(branch).")
                }
                try await check()
            })
        } catch let error where !(error is ToolRefusal) && Self.mayHaveLanded(error) {
            throw ToolRefusal("AiTerm doesn’t know whether \(reference)’s pipeline was retried: \(error.localizedDescription) "
                              + "Call retry_pipeline again: it says whether the pipeline runs now.")
        }
        switch result {
        case .notFailed(let why): throw ToolRefusal("\(reference) has nothing to retry: \(why).")
        case .retried(let what):
            return ["task": .string(key), "mergeRequest": publication.mergeRequestURL.map(JSONValue.string) ?? .null, "retried": .string(what)]
        }
    }

    /// `text` when it says something; nil for none, or only whitespace.
    private static func said(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
