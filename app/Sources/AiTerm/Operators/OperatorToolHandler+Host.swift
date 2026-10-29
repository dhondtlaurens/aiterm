import Foundation
import AiTermCore

/// What the host says of each task's request (spec §11): draft, pipeline, mergeability, approvals. `run_status` and
/// `read_task` show it so the Operator needn't guess whether AiTerm marked a request ready or its pipeline failed. A read
/// goes through the network, so it never runs on the main thread, never delays the answer past `OperatorPorts.hostTimeout`,
/// is kept for `hostCache`, and never fails the tool: a host that doesn't answer leaves `mergeRequestNote`.
extension OperatorToolHandler {
    /// What a read of one request came to.
    enum HostReading: Equatable, Sendable {
        case state(MergeRequestState), note(String)
    }

    /// The host, Jira or the Oracle did not answer within the limit (`within`).
    struct NoAnswer: Error {}

    /// Fills `mergeRequest`, or `mergeRequestNote`, on every task of `status` that has a request, asking the hosts together.
    func fillMergeRequests(_ status: inout RunStatus) async {
        // One task each, started together: every host answers or times out inside the same few seconds.
        let jobs = status.tasks.map(\.id).map { id in
            (id, Task { @MainActor () -> HostReading? in
                guard let task = self.state.task(id: id) else { return nil }
                return await self.hostState(of: task)
            })
        }
        var readings: [UUID: HostReading] = [:]
        for (id, job) in jobs { readings[id] = await job.value }
        for index in status.tasks.indices {
            switch readings[status.tasks[index].id] {
            case .state(let state)?: status.tasks[index].mergeRequest = state
            case .note(let note)?: status.tasks[index].mergeRequestNote = note
            case nil: break
            }
        }
    }

    /// The host's view of `task`'s request: nil when it has none. A reading under `hostCache` old is the last one; one that
    /// failed is not kept, so the next call asks again.
    func hostState(of task: TaskItem) async -> HostReading? {
        guard let publication = task.operated?.publication, let number = publication.mergeRequestNumber,
              let url = publication.mergeRequestURL else { return nil }
        let key = HostReadKey(project: task.projectId, repository: publication.repository, url: url,
                              number: number, acceptedSHA: task.operated?.acceptance?.resultSHA)
        if let kept = hostStates[key], ports.now().timeIntervalSince(kept.at) < ports.hostCache { return .state(kept.state) }
        if let pending = hostReads[key] { return await pending.task.value }
        let id = UUID()
        let reading = Task { await self.readHost(task, publication: publication, number: number, url: url) }
        hostReads[key] = HostRead(id: id, task: reading)
        let answer = await reading.value
        // A stop may have discarded this job and a resumed caller started another one for the same request.
        if hostReads[key]?.id == id {
            hostReads[key] = nil
            if case .state(let value) = answer {
                let now = ports.now()
                hostStates = hostStates.filter { now.timeIntervalSince($0.value.at) < ports.hostCache }
                hostStates[key] = (now, value)
            }
        }
        return answer
    }

    private func readHost(_ task: TaskItem, publication: TaskPublication, number: Int, url: String) async -> HostReading {
        let request = MergeRequest(iid: number, title: task.title, sourceBranch: task.branch, targetBranch: publication.targetBranch ?? "",
                                   author: nil, state: "opened", draft: false, url: url)
        let limit = ports.hostTimeout
        let answer = await Self.within(limit) { [self] in
            let host = try await reviewHost(of: task, request: publication)
            return try await host.state(of: request)
        }
        switch answer {
        case .success(let state): return .state(state)
        case .failure(let error):
            let why = error is NoAnswer ? "the host did not answer in \(Int(limit.components.seconds)) seconds"
                : (error as? ToolRefusal)?.message ?? error.localizedDescription
            return .note("AiTerm couldn’t read its \(CodeHost(webURL: url).reference(number)) on the host: \(why)")
        }
    }

    func cancelHostReads() {
        for reading in hostReads.values { reading.task.cancel() }
        hostReads.removeAll()
        hostStates.removeAll()
    }

    /// `work`, or `NoAnswer` when it has not ended within `limit`. The race is between two tasks started here, not a task
    /// group, so a host call that ignores cancellation is left behind instead of holding the answer up. The loser is
    /// cancelled, `work` too unless `cancelling` is false: a wait that must go on after the answer (an Oracle's critique).
    static func within<Value: Sendable>(_ limit: Duration, cancelling: Bool = true,
                                        _ work: @escaping @MainActor @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        let (finished, report) = AsyncStream<Result<Value, any Error>>.makeStream()
        let working = Task { @MainActor in
            do { report.yield(.success(try await work())) } catch { report.yield(.failure(error)) }
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            report.yield(.failure(NoAnswer()))
        }
        var first: Result<Value, any Error> = .failure(NoAnswer())
        for await result in finished { first = result; break }
        if cancelling { working.cancel() }
        timer.cancel()
        return first
    }
}
