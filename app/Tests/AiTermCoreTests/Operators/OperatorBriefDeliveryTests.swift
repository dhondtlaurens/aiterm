import Testing
import Foundation
@testable import AiTermCore
import AiTermTestSupport

/// A broadcast reaches its Operator as the person typed it: the prompt, Review and Done in
/// `first-message.md`, the Review, Done and Instructions in `brief.md`, and the first message through
/// the shell that runs the Operator's command, byte for byte, whatever the text holds (`TypedText`).
@Suite struct OperatorBriefDeliveryTests {
    typealias F = OperatorFixtures
    let token = String(repeating: "ab", count: 32)

    /// Over 100 KB in all, the prompt alone over it, each with lines over 4,000 characters.
    private func typedRun() -> OperatorRun {
        var run = F.run()
        run.prompt = TypedText.text("Prompt", longLines: 4, bytes: 110_000)
        run.taskSettings.review = TypedText.text("Review")
        run.goal = BroadcastGoal(text: TypedText.text("Goal"))
        run.profile.instructions = TypedText.text("Instructions", bytes: 20_000)
        return run
    }

    private func prepared(_ run: OperatorRun) throws -> (home: URL, prepared: OperatorCommand.Prepared) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("operator-brief-\(UUID().uuidString)")
        return (home, try OperatorCommand.prepare(run: run, projects: [F.project(path: "/code/it's a \"shop\"")], home: home, token: token))
    }

    private func holds(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    /// `state.json` keeps the broadcast as typed, for a relaunch's brief and first message.
    @Test func theSavedBroadcastKeepsItsText() throws {
        let run = typedRun()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = AppState()
        state.runs = [run]

        try StateStore(url: url).save(state)
        let saved = try #require(try StateStore(url: url).load().runs.first)

        #expect(Array(saved.prompt.utf8) == Array(run.prompt.utf8))
        #expect(saved.taskSettings.review.map { Array($0.utf8) } == run.taskSettings.review.map { Array($0.utf8) })
        #expect(saved.goal.map { Array($0.text.utf8) } == run.goal.map { Array($0.text.utf8) })
        #expect(Array(saved.profile.instructions.utf8) == Array(run.profile.instructions.utf8))
    }

    @Test func theFirstMessageAndTheBriefAreWrittenWhole() throws {
        let run = typedRun()
        let (home, prepared) = try prepared(run)
        defer { try? FileManager.default.removeItem(at: home) }
        let review = try #require(run.taskSettings.review), done = try #require(run.goal?.text)

        let first = try Data(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile))
        #expect(first == Data(("Your broadcast:\n\n" + run.prompt + "\n\nEach task is reviewed with: " + review + "\n\nGoal: " + done).utf8))
        #expect(first.count > 100_000)
        let brief = try Data(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.briefFile))
        #expect(holds(brief, "\nReview: " + review + "\n"))
        #expect(holds(brief, "\nGoal: " + done + "\n"))
        #expect(holds(brief, "\n## Instructions\n\n" + run.profile.instructions + "\n\n## Remember\n"))
    }

    /// The command line hands `claude` each word and the first message as one argument each, with
    /// nothing expanded, split or lost. `printf` stands in for `claude` and prints what it is handed.
    @Test(arguments: ["/bin/zsh", "/bin/bash", "/bin/sh"])
    func theCommandHandsTheFirstMessageOverByteForByte(shell: String) throws {
        let run = typedRun()
        let (home, prepared) = try prepared(run)
        defer { try? FileManager.default.removeItem(at: home) }
        let words = OperatorCommand.launchWords(model: run.profile.model, effort: run.profile.reasoning, runFolder: prepared.folder,
                                                projectPaths: ["/code/it's a \"shop\""])
        // The gate's denials put the line past the typed-line limit: the window types a read of `launch.sh`, which holds it.
        #expect(try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.launchFile), encoding: .utf8)
                == OperatorCommand.command(words: words, firstMessage: true), "the command tested is the one prepared")
        let message = try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)

        let printing = OperatorCommand.command(words: ShellLine.printing + words.dropFirst(), firstMessage: true)
        let ran = try ShellLine.run(shell, printing, in: prepared.folder)

        #expect(ran.status == 0)
        #expect(ran.out == ShellLine.printed(words.dropFirst() + [message]))
    }

    /// The command is typed into the person's own shell, where an alias or a function named `cat`
    /// (one that pages, colours or numbers its output) would hand Claude its output rather than the file.
    @Test(arguments: [("/bin/zsh", "alias cat='tr a-z A-Z'"), ("/bin/zsh", "cat() { echo replaced; }"),
                      ("/bin/bash", "cat() { echo replaced; }"), ("/bin/sh", "cat() { echo replaced; }")])
    func aShellsOwnCatNeverRewritesTheFirstMessage(shell: String, definition: String) throws {
        let run = typedRun()
        let (home, prepared) = try prepared(run)
        defer { try? FileManager.default.removeItem(at: home) }
        let message = try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)

        let printing = OperatorCommand.command(words: ShellLine.printing, firstMessage: true)
        // Defined first, then the line parsed, as a person's rc file defines it before the command is typed.
        let ran = try ShellLine.run(shell, definition + "\neval \"$1\"", argument: printing, in: prepared.folder)

        #expect(ran.out == ShellLine.printed([message]))
    }

    /// A line past `AgentCommand.inlineLimit` would be cut by a terminal still in canonical mode, so
    /// the command goes to `launch.sh` in the run folder and the line typed only reads it, as a task's
    /// long first prompt goes to `.aiterm/first-prompt.md`. Run, it hands `claude` the same words.
    @Test(arguments: ["/bin/zsh", "/bin/bash", "/bin/sh"])
    func aCommandTooLongToTypeIsReadFromTheRunFolder(shell: String) throws {
        let run = typedRun()
        let paths = (1...20).map { "/Users/someone/Sites/clients/it's project \($0) with a long \"name\"" }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("operator-brief-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let prepared = try OperatorCommand.prepare(run: run, projects: paths.map { F.project(id: UUID(), path: $0) }, home: home, token: token)
        let words = OperatorCommand.launchWords(model: run.profile.model, effort: run.profile.reasoning, runFolder: prepared.folder,
                                                projectPaths: paths)
        let line = OperatorCommand.command(words: words, firstMessage: true)
        #expect(line.utf8.count > AgentCommand.inlineLimit)

        #expect(prepared.command == "eval \"$(command cat launch.sh)\"")
        #expect(prepared.command.utf8.count <= AgentCommand.inlineLimit)
        let launch = prepared.folder.appendingPathComponent(OperatorCommand.launchFile)
        #expect(try String(contentsOf: launch, encoding: .utf8) == line)
        #expect(try FileManager.default.attributesOfItem(atPath: launch.path)[.posixPermissions] as? Int == 0o600,
                "readable by you alone, as the token is")
        let message = try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)
        let ran = try ShellLine.run(shell, "claude() { /usr/bin/printf '%s\\0' \"$@\"; }\neval \"$1\"", argument: prepared.command,
                                    in: prepared.folder)
        #expect(ran.status == 0)
        #expect(ran.out == ShellLine.printed(words.dropFirst() + [message]))

        // A later line short enough to type leaves no stale file to be read.
        #expect(try OperatorCommand.typed("claude -p", in: prepared.folder) == "claude -p")
        #expect(!FileManager.default.fileExists(atPath: launch.path))
    }
}
