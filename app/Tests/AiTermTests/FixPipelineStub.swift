import Foundation
@testable import AiTermCore

// Here and not in AiTermTestSupport: a clone and a landing are built with Core's internal
// memberwise inits, which only a test target's `@testable` import reaches.

extension FixPipeline {
    /// A pipeline that never touches git: `prepare` makes an empty folder, `look` answers `look`
    /// (after 30 s when `slowLook`, so a test can cancel it), `apply` does nothing, `land` returns
    /// a fixed landing.
    static func stub(look: FixLook, slowLook: Bool = false) -> FixPipeline {
        FixPipeline(
            prepare: { request throws(FixRefusal) in
                let dir = NSTemporaryDirectory() + FixClone.prefix + "stub-" + UUID().uuidString
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return FixClone(path: dir, branch: request.branch, startTip: "a", originTip: "b", git: GitRunner())
            },
            look: { _, _, _ throws(FixRefusal) in
                if slowLook { try? await Task.sleep(for: .seconds(30)) }
                return (look, "S")
            },
            apply: { _, _, _, _ in },
            land: { clone in FixLanding(branch: clone.branch, old: "a", new: "c") })
    }
}

extension FixRequest {
    static let sample = FixRequest(title: "Couldn’t pull the default branch.", reason: nil, detail: nil, projectPath: "/p",
                                   branch: "main", recreateRebase: false, retry: .pullDefault(UUID()))
}
