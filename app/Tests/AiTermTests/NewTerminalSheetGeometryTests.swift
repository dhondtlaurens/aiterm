import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct NewTerminalSheetGeometryTests {
    /// New Terminal is one of AiTerm's creation sheets, so it must keep the same footprint as
    /// New Task instead of falling back to its old compact, self-sized presentation.
    @Test func usesTheStandardCreationSheetFootprint() {
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let sheet = NewTerminalSheet(project: project, suggestedName: "Terminal", branch: "main",
                                     canCreate: true, createTerminal: { _ in })
        let host = NSHostingView(rootView: sheet)

        #expect(host.fittingSize.width == 560)
        #expect(host.fittingSize.height == 560)
    }
}
