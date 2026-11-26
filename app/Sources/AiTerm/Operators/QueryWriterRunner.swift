import Foundation
import AiTermCore

/// Writes a trigger's query from the person's description: one read-only headless Claude run with the Operator's model and
/// reasoning, in a scratch folder that reads no project, then AiTerm's check of the answer. A query that fails the check
/// goes back to Claude once, with the error.
struct QueryWriterRunner: Sendable {
    enum Outcome: Equatable, Sendable {
        /// A query that passed its check.
        case written(String)
        /// Why there is no checked query, with the last query Claude wrote, if any, for the person to fix.
        case failed(String, query: String?)
    }

    /// What checking a query found.
    enum Check: Equatable, Sendable {
        case passed
        /// The query cannot run, and why. Claude gets one more try with it.
        case refused(String)
        /// The check itself could not run, and why. The query is kept, unchecked.
        case unchecked(String)
    }

    typealias Checker = @Sendable (_ source: SignalTrigger.Source, _ start: Bool, _ query: String) async -> Check

    var headless: HeadlessRun
    var check: Checker
    /// The Operator's model and reasoning.
    var model: String, reasoning: String?
    var timeout: Duration = Self.timeout

    /// About a minute: one query, with nothing to read but the prompt.
    static let timeout: Duration = .seconds(60)

    func write(source: SignalTrigger.Source, start: Bool, description: String, context: QueryWriter.Context) async -> Outcome {
        let trigger: QueryWriter.Trigger = start ? .start : .done
        let first = await attempt(QueryWriter.prompt(source: source, trigger: trigger, description: description, context: context),
                                  source: source, start: start)
        let rejected: String, error: String, firstQuery: String?
        switch first {
        case .noAnswer(let why): return .failed(why, query: nil)
        case .checked(let query, .passed): return .written(query)
        case .checked(let query, .unchecked(let why)): return .failed(why, query: query)
        case .checked(let query, .refused(let why)): rejected = query; error = why; firstQuery = query
        case .noQuery(let answer): rejected = answer; error = "The answer was not a single query on one line."; firstQuery = nil
        }
        let retry = QueryWriter.retryPrompt(source: source, trigger: trigger, description: description, context: context,
                                            rejected: rejected, error: error)
        switch await attempt(retry, source: source, start: start) {
        case .noAnswer(let why): return .failed(why, query: firstQuery)
        case .noQuery: return .failed("Claude gave no query.", query: firstQuery)
        case .checked(let query, .passed): return .written(query)
        case .checked(let query, .unchecked(let why)): return .failed(why, query: query)
        case .checked(let query, .refused(let why)): return .failed("Claude’s query still fails: " + why, query: query)
        }
    }

    private enum Attempt { case noAnswer(String), noQuery(String), checked(String, Check) }

    private func attempt(_ prompt: String, source: SignalTrigger.Source, start: Bool) async -> Attempt {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-query-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return .noAnswer("Claude couldn’t run: " + error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let invocation = QueryWriter.invocation(prompt: prompt, folder: folder.path, model: model, reasoning: reasoning)
        switch await headless.perform(invocation, in: folder.path, timeout: timeout) {
        case .failure(.missing): return .noAnswer("Claude Code isn’t installed.")
        case .failure(let why): return .noAnswer(why.text(of: "Claude"))
        case .success(let output):
            guard let answer = QueryWriter.answer(output) else { return .noAnswer("Claude gave no answer (exit \(output.status)).") }
            guard let query = QueryWriter.query(from: answer) else { return .noQuery(answer) }
            return .checked(query, await check(source, start, query))
        }
    }
}

extension SignalConnections {
    /// Whether `query` runs as a Start (`start`) or Done query of `source`: AiTerm's own reading first, then Jira's strict
    /// parse for JQL and one page of GitHub's search for a GitHub query. GitLab's syntax is AiTerm's alone.
    func check(_ source: SignalTrigger.Source, start: Bool, query: String) async -> QueryWriterRunner.Check {
        // A cron is AiTerm's alone; its project is chosen apart from it.
        if source == .schedule {
            do { _ = try Cron(query); return .passed } catch { return .refused(error.message) }
        }
        if let refusal = SignalTrigger(source: source, query: query).refusal(start: start) { return .refused(refusal.message) }
        switch source {
        case .jira:
            guard let jira else { return .unchecked("Connect Jira in Settings to check it.") }
            do {
                let errors = try await JiraClient(config: jira, session: session).jqlErrors(query)
                return errors.isEmpty ? .passed : .refused(errors.joined(separator: " "))
            } catch { return .unchecked("Jira couldn’t check it. " + OperationIssue.reason(of: error)) }
        case .gitHub:
            guard let gitHub else { return .unchecked("Connect GitHub in Settings to check it.") }
            do {
                try await GitHubAccount(config: gitHub, session: session).check(start ? GitHubQuery.start(query) : GitHubQuery.done(query))
                return .passed
            } catch GitHubError.refused(let why) {
                return .refused(why)
            } catch { return .unchecked("GitHub couldn’t check it. " + OperationIssue.reason(of: error)) }
        case .gitLab, .schedule, .operator, .person, .unknown:
            return .passed
        }
    }

    /// What the query writer is told of the person's accounts and `projects`. A read that fails leaves its part out.
    func writerContext(projects: [Project]) async -> QueryWriter.Context {
        let jira = self.jira.map { JiraClient(config: $0, session: session) }
        let gitLab = self.gitLab.map { GitLabAccount(config: $0, session: session) }
        let gitHub = self.gitHub.map { GitHubAccount(config: $0, session: session) }
        async let jiraUser = Self.read { try await jira?.testConnection() }
        async let statuses = Self.read { try await jira?.statuses(limit: 200).map(\.name) }
        async let labels = Self.read { try await jira?.labels(limit: 100) }
        async let gitLabUser = Self.read { try await gitLab?.user() }
        async let gitHubUser = Self.read { try await gitHub?.user() }
        var context = QueryWriter.Context(projects: projects)
        context.jiraUser = await jiraUser; context.statuses = await statuses ?? []; context.labels = await labels ?? []
        context.gitLabUser = await gitLabUser; context.gitHubUser = await gitHubUser
        context.now = Date(); context.timeZone = .current
        return context
    }

    private static func read<Value: Sendable>(_ body: @Sendable () async throws -> Value?) async -> Value? { try? await body() }
}
