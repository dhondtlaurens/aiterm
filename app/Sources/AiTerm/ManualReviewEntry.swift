import AiTermCore
import Darwin
import Foundation
import Synchronization

/// Terminal entry point. The foreground helper relays interruption to its headless child.
enum ManualReviewEntry {
    static func runIfRequested() -> Bool {
        let words = Array(CommandLine.arguments.dropFirst())
        if words.first == "--manual-review-read" {
            let permitted = words.count == 2 && ManualReviewAgy.permits(FileHandle.standardInput.readDataToEndOfFile(),
                                                                        workspace: URL(fileURLWithPath: words[1]))
            line(permitted ? #"{"decision":"allow"}"# : #"{"decision":"deny","reason":"AiTerm permits only reads of the pinned review inputs."}"#)
            exit(0)
        }
        guard words.first == "--manual-review" else { return false }
        guard words.count == 2 else { line("Missing review request."); exit(1) }
        let done = DispatchSemaphore(value: 0), status = Mutex<Int32>(1)
        let task = Task.detached {
            defer { done.signal() }
            do {
                try await ManualReview.withClaim(at: URL(fileURLWithPath: words[1])) { review, folder in
                    try await run(review, folder: folder)
                }
                status.withLock { $0 = 0 }
            } catch {
                line("Review failed. " + (error is CancellationError ? "Review interrupted." : error.localizedDescription))
            }
        }
        let sources = [SIGINT, SIGHUP, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { task.cancel() }
            source.resume()
            return source
        }
        withExtendedLifetime(sources) { done.wait() }
        exit(status.withLock { $0 })
    }

    static func run(_ review: ManualReview, folder: URL,
                    makeRunner: @Sendable (AgentKind, FileHandle) -> HeadlessRun = HeadlessRun.manualReview(agent:capture:),
                    timeout: Duration = .seconds(900)) async throws {
        line("Reviewing " + review.branch + " at " + review.head + " with " + review.agent.displayName)
        // A terminal may have inherited a worktree-specific git environment. The saved request
        // supplies the repository; keep transport configuration but never inherit another index or object store.
        let localGitKeys: Set<String> = ["GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_SHALLOW_FILE", "GIT_PREFIX"]
        let repository = Repository(review.repository, git: GitRunner(ignoringInherited: { localGitKeys.contains($0) }))
        let input = try await BackgroundWork.run { try repository.prepareManualReview(head: review.head, target: review.target, in: folder) }
        try Task.checkCancellation()
        line("Target " + input.target + " · merge base " + input.base)
        if input.empty { line("No changes in the reviewed range."); return }
        try PrivateFile.write(Data((review.context ?? "").utf8), to: input.workspace.appendingPathComponent("context.txt"))
        let answer = folder.appendingPathComponent("answer"), events = folder.appendingPathComponent("events")
        try PrivateFile.write(Data(), to: events)
        let file = try FileHandle(forWritingTo: events)
        defer { try? file.close() }
        let profile = review.agent == .agy ? try ManualReviewAgy.install(in: input.workspace, executable: Bundle.main.executableURL!) : nil
        let invocation = try review.invocation(workspace: input.workspace, answerFile: answer, profile: profile)
        let runner = makeRunner(review.agent, file)
        switch await runner.perform(invocation, in: input.workspace.path, timeout: timeout) {
        case .failure(let reason): throw ManualReviewError(reason.text(of: review.agent.displayName))
        case .success(let output):
            guard !output.stdoutTruncated else { throw ManualReviewError("Could not capture the complete reviewer output within the capture limit.") }
            guard output.status == 0 else {
                throw ManualReviewError("\(review.agent.displayName) exited with status \(output.status). " + String(output.stderr.suffix(1000)))
            }
            line(try review.agent.manualReviewAnswer(events: events, answerFile: invocation.answerFile))
        }
    }

    static func line(_ text: String) {
        let clean = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        try? FileHandle.standardOutput.write(contentsOf: Data((String(clean) + "\n").utf8))
    }
}
