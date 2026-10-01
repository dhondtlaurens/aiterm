import Foundation
import Testing
@testable import AiTermCore

/// The real `hooks/claude-statusline-shim.sh`, run in a temporary home with `curl` and `python3`
/// replaced by recorders on `PATH`: nothing reaches a running daemon, and the test sees exactly
/// what the shim would have started. Claude Code runs it on every status-line tick.
@Suite struct StatusLineShimTests {
    static let shim = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/claude-statusline-shim.sh")
    let payload = #"{"model":{"id":"claude-opus-5"},"rate_limits":{"five_hour":{"used_percentage":23.4}}}"#

    struct Home {
        let url: URL
        var support: URL { url.appendingPathComponent("Library/Application Support/AiTerm") }
        var curlArguments: URL { url.appendingPathComponent("curl-args") }
        var curlInput: URL { url.appendingPathComponent("curl-stdin") }
        var pythonRuns: URL { url.appendingPathComponent("python3-runs") }
    }

    func makeHome() throws -> Home {
        let home = Home(url: FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-shim-\(UUID().uuidString)"))
        let bin = home.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
        // Written to a temporary name and moved into place, so a poll never sees half a file.
        try recorder(at: bin.appendingPathComponent("curl"), """
            cat > "$HOME/curl-stdin.tmp"; printf '%s\\n' "$@" > "$HOME/curl-args.tmp"
            mv "$HOME/curl-stdin.tmp" "$HOME/curl-stdin"; mv "$HOME/curl-args.tmp" "$HOME/curl-args"
            """)
        try recorder(at: bin.appendingPathComponent("python3"), #"echo run >> "$HOME/python3-runs""#)
        return home
    }

    func recorder(at url: URL, _ body: String) throws {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func run(_ home: Home) throws -> ProcessOutput {
        let input = home.url.appendingPathComponent("input.json")
        try Data(payload.utf8).write(to: input)
        let bin = home.url.appendingPathComponent("bin").path
        return try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", #""$0" < "$1""#, Self.shim.path, input.path],
                                     environment: ["HOME": home.url.path, "PATH": "\(bin):/usr/bin:/bin"], timeout: 10)
    }

    /// The POST is fired into the background so the status line is never held up; wait for it. The
    /// happy path answers in ~100 ms — this deadline only bounds a failure, so it is generous
    /// enough to survive the scheduling delays of a fully loaded machine (the full suite's other
    /// concurrent test hosts) without masking a real one.
    func forwarded(_ home: Home) async throws -> (arguments: [String], body: String)? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let arguments = try? String(contentsOf: home.curlArguments, encoding: .utf8) {
                return (arguments.split(separator: "\n").map(String.init), try String(contentsOf: home.curlInput, encoding: .utf8))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test func forwardsToTheAppsHookPortAndRunsTheOriginalCommandWithoutPython() async throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home.url) }
        try Data(#"printf 'mine:'; cat"#.utf8).write(to: home.support.appendingPathComponent("statusline-original.cmd"))
        let output = try run(home)
        #expect(output.status == 0)
        #expect(output.stdout == "mine:" + payload)
        #expect(output.stderr == "")
        let post = try #require(try await forwarded(home))
        #expect(post.arguments.last == "http://127.0.0.1:\(AiTermPaths.hookPort)/statusline")
        #expect(post.body == payload)
        #expect(!FileManager.default.fileExists(atPath: home.pythonRuns.path), "a status-line tick must not start python3")
    }

    @Test func withoutAnOriginalCommandItIsSilentAndStillForwards() async throws {
        for original: String? in [nil, ""] {
            let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home.url) }
            if let original { try Data(original.utf8).write(to: home.support.appendingPathComponent("statusline-original.cmd")) }
            let output = try run(home)
            #expect(output.status == 0)
            #expect(output.stdout == "")
            #expect(output.stderr == "")
            #expect(try await forwarded(home)?.body == payload)
        }
    }

    @Test func anUnreadableCommandFileIsSilentAndStillForwards() async throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home.url) }
        let command = home.support.appendingPathComponent("statusline-original.cmd")
        try Data("printf 'mine:'; cat".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: command.path)
        let output = try run(home)
        #expect(output.status == 0)
        #expect(output.stdout == "")
        #expect(output.stderr == "")
        #expect(try await forwarded(home)?.body == payload)
    }
}
