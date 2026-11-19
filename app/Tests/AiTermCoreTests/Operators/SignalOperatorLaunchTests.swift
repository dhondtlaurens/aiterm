import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct SignalOperatorLaunchTests {
    @Test(.blocking) func onePrivateFolderReusesOnlyTheCurrentGenerationsTokenAndDisablesIdleCompaction() async throws {
        try await BackgroundWork.run {
            let home = try ScratchFolder.make("aiterm-signal-launch-")
            defer { try? FileManager.default.removeItem(at: home) }
            var session = OperatorSession(createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            var state = AppState.empty; state.operatorSession = session
            let digest = OperatorDigest(state: state, at: session.createdAt, oracleOn: true)
            let profile = OperatorProfile(model: "sonnet", reasoning: "high", instructions: "Use the repository's own checks.")
            let first = try OperatorLaunch.prepare(session: session, profile: profile, digest: digest, home: home)
            let same = try OperatorLaunch.prepare(session: session, profile: profile, digest: digest, home: home)
            #expect(first.folder == OperatorLaunch.folder(home: home))
            #expect(first.token == same.token)
            #expect(first.folder.lastPathComponent == "operator")
            let gateBytes = try Data(contentsOf: first.folder.appendingPathComponent("gate.json"))
            let expectedGate = #"{"env":{"BASH_MAX_OUTPUT_LENGTH":"16000"},"hooks":{"PreToolUse":[{"hooks":[{"headers":{"Authorization":"Bearer \#(first.token)","X-AiTerm-Hook":"1"},"timeout":240,"type":"http","url":"http://127.0.0.1:\#(AiTermPaths.hookPort)/operator/gate"}],"matcher":"Bash"}]},"idleCompaction":false}"#
            #expect(gateBytes == Data(expectedGate.utf8))
            let gate = try JSONDecoder().decode(JSONValue.self, from: gateBytes)
            #expect(gate["idleCompaction"] == false)
            #expect(gate["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
            let brief = try String(contentsOf: first.folder.appendingPathComponent("brief.md"), encoding: .utf8)
            #expect(brief.hasSuffix("Use the repository's own checks.\n"))
            for name in ["token", "session.json", "mcp.json", "gate.json"] {
                let mode = try FileManager.default.attributesOfItem(atPath: first.folder.appendingPathComponent(name).path)[.posixPermissions] as? Int
                #expect(mode == 0o600)
            }
            session.generation += 1
            let fresh = try OperatorLaunch.prepare(session: session, profile: profile, digest: digest, home: home)
            #expect(fresh.folder == first.folder && fresh.token != first.token)
            #expect(try OperatorLaunch.authority(in: first.folder)?.generation == 2)
        }
    }

    /// Claude asks to trust each `--add-dir` folder it has no saved trust for, and never saves it
    /// for the home folder: a project there would stop every launch on that question. The Operator
    /// adds no folder and reads through allowed Read, Grep and Glob instead.
    @Test(.blocking) func theLaunchAddsNoFolderAndAllowsTheReadTools() async throws {
        let folder = URL(fileURLWithPath: "/run")
        func allowed(_ words: [String]) -> [String] {
            Array(words.drop { $0 != "--allowedTools" }.dropFirst().prefix { !$0.hasPrefix("--") })
        }
        for words in [OperatorLaunch.launchWords(model: "sonnet", effort: "high", folder: folder),
                      OperatorLaunch.launchWords(model: "sonnet", effort: "high", folder: folder, resuming: "c0nv")] {
            #expect(!words.contains("--add-dir"))
            #expect(allowed(words) == ["mcp__aiterm__*", "Bash", "Read", "Grep", "Glob"])
            #expect(words.last == "--strict-mcp-config")
        }
        try await BackgroundWork.run {
            let home = try ScratchFolder.make("aiterm-signal-launch-")
            defer { try? FileManager.default.removeItem(at: home) }
            let session = OperatorSession(createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            var state = AppState.empty; state.operatorSession = session
            let digest = OperatorDigest(state: state, at: session.createdAt, oracleOn: true)
            let prepared = try OperatorLaunch.prepare(session: session, profile: OperatorProfile(model: "sonnet", reasoning: "high", instructions: ""),
                                                      digest: digest, home: home)
            let line = (try? String(contentsOf: prepared.folder.appendingPathComponent(OperatorLaunch.launchFile), encoding: .utf8)) ?? prepared.command
            #expect(!line.contains("--add-dir"))
            #expect(line.contains("--allowedTools 'mcp__aiterm__*' Bash Read Grep Glob --strict-mcp-config"))
        }
    }

    @Test func theCurrentContextTokensDecodeWithoutBreakingOlderSessions() throws {
        let bytes = Data(#"{"sessionId":"s","windowId":"w","active":false,"work":[],"tabIndex":0,"agent":"claude","state":"idle","title":"Operator","cwd":"/operator","contextTokens":39239}"#.utf8)
        let session = try JSONDecoder().decode(SessionInfo.self, from: bytes)
        #expect(session.contextTokens == 39239)
        let old = Data(#"{"sessionId":"s","windowId":"w","active":false,"work":[],"tabIndex":0,"agent":"claude","state":"idle","title":"Operator","cwd":"/operator"}"#.utf8)
        #expect(try JSONDecoder().decode(SessionInfo.self, from: old).contextTokens == nil)
    }
}
