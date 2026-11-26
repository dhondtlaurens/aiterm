import Foundation

extension UpdateScript {
    /// 2.1.0: the Operator's snag reports are retired. No screen had shown them since broadcasts went,
    /// and the Operator no longer records or reads them, so the saved `operatorSession.snags` is dropped.
    static let update2_1_0 = UpdateScript(
        version: ReleaseVersion(major: 2, minor: 1, patch: 0),
        summary: "Drops the Operator's retired snag reports."
    ) { context in
        context.state.edit("operatorSession") { $0["snags"] = nil }
    }
}
