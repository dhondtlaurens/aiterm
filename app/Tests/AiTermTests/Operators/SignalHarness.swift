import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor struct SignalHarness {
    let folder: URL, file: StateStore, workspace: WorkspaceStore, journal: SignalJournal
    init(_ world: SignalWorld) throws {
        folder = try ScratchFolder.make("aiterm-signals-engine-")
        file = StateStore(url: folder.appendingPathComponent("state.json"))
        try file.save(world.state)
        workspace = WorkspaceStore(file: file); try workspace.load()
        journal = SignalJournal(workspace: workspace, folder: folder.appendingPathComponent("journals"), now: { world.now })
    }
    func cleanUp() { workspace.flush(); try? FileManager.default.removeItem(at: folder) }
}
