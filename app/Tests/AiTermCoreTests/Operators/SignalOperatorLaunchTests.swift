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
            let first = try SignalOperatorCommand.prepare(session: session, profile: profile, projects: [], digest: digest, home: home)
            let same = try SignalOperatorCommand.prepare(session: session, profile: profile, projects: [], digest: digest, home: home)
            #expect(first.folder == SignalOperatorCommand.folder(home: home))
            #expect(first.token == same.token)
            #expect(first.folder.lastPathComponent == "operator")
            let gate = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: first.folder.appendingPathComponent("gate.json")))
            #expect(gate["idleCompaction"] == false)
            #expect(gate["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
            let brief = try String(contentsOf: first.folder.appendingPathComponent("brief.md"), encoding: .utf8)
            #expect(brief.hasSuffix("Use the repository's own checks.\n"))
            for name in ["token", "session.json", "mcp.json", "gate.json"] {
                let mode = try FileManager.default.attributesOfItem(atPath: first.folder.appendingPathComponent(name).path)[.posixPermissions] as? Int
                #expect(mode == 0o600)
            }
            session.generation += 1
            let fresh = try SignalOperatorCommand.prepare(session: session, profile: profile, projects: [], digest: digest, home: home)
            #expect(fresh.folder == first.folder && fresh.token != first.token)
            #expect(try SignalOperatorCommand.authority(in: first.folder)?.generation == 2)
        }
    }

    @Test func theCurrentContextTokensDecodeWithoutBreakingOlderSessions() throws {
        let bytes = Data(#"{"sessionId":"s","windowId":"w","active":false,"background":[],"tabIndex":0,"agent":"claude","state":"idle","title":"Operator","cwd":"/operator","contextTokens":39239}"#.utf8)
        let session = try JSONDecoder().decode(SessionInfo.self, from: bytes)
        #expect(session.contextTokens == 39239)
        let old = Data(#"{"sessionId":"s","windowId":"w","active":false,"background":[],"tabIndex":0,"agent":"claude","state":"idle","title":"Operator","cwd":"/operator"}"#.utf8)
        #expect(try JSONDecoder().decode(SessionInfo.self, from: old).contextTokens == nil)
    }
}
