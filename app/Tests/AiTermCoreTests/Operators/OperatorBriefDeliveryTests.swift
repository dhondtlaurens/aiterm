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
        run.review = TypedText.text("Review")
        run.done = TypedText.text("Done")
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
        #expect(saved.review.map { Array($0.utf8) } == run.review.map { Array($0.utf8) })
        #expect(saved.done.map { Array($0.utf8) } == run.done.map { Array($0.utf8) })
        #expect(Array(saved.profile.instructions.utf8) == Array(run.profile.instructions.utf8))
    }

    @Test func theFirstMessageAndTheBriefAreWrittenWhole() throws {
        let run = typedRun()
        let (home, prepared) = try prepared(run)
        defer { try? FileManager.default.removeItem(at: home) }
        let review = try #require(run.review), done = try #require(run.done)

        let first = try Data(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile))
        #expect(first == Data(("Your broadcast:\n\n" + run.prompt + "\n\nReview: " + review + "\n\nDone: " + done).utf8))
        #expect(first.count > 100_000)
        let brief = try Data(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.briefFile))
        #expect(holds(brief, "\nReview: " + review + "\nDone: " + done + "\n"))
        #expect(holds(brief, "\n## Instructions\n\n" + run.profile.instructions + "\n\n## Run rules\n"))
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
        #expect(prepared.command == OperatorCommand.command(words: words, firstMessage: true), "the command tested is the one prepared")
        let message = try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)

        let printing = OperatorCommand.command(words: [Self.printf, Self.eachArgument] + words.dropFirst(), firstMessage: true)
        let out = try Self.run(shell, printing, in: prepared.folder)

        #expect(out == Data((words.dropFirst() + [message]).map { $0 + "\0" }.joined().utf8))
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

        let printing = OperatorCommand.command(words: [Self.printf, Self.eachArgument], firstMessage: true)
        // Defined first, then the line parsed, as a person's rc file defines it before the command is typed.
        let out = try Self.run(shell, definition + "\neval \"$1\"", argument: printing, in: prepared.folder)

        #expect(out == Data((message + "\0").utf8))
    }

    private static let printf = "/usr/bin/printf"
    /// Each argument after it, NUL-ended: `printf`'s own `%s` and `\0`.
    private static let eachArgument = "%s\\0"

    /// `script` run by `shell -c` in `folder`, with no rc files, `argument` as its `$1`; what it printed.
    private static func run(_ shell: String, _ script: String, argument: String? = nil, in folder: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = (shell.hasSuffix("zsh") ? ["-f"] : []) + ["-c", script] + (argument.map { ["_", $0] } ?? [])
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "LANG": "en_US.UTF-8"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(shell) exited \(process.terminationStatus)")
        return data
    }
}
