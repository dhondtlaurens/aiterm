import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct NewTerminalSheetGeometryTests {
    /// New Terminal is one of AiTerm's creation sheets, so it keeps their width; but it asks one
    /// question, so it is as tall as its field, its title and its footer — short of `Sheet.height`,
    /// which it would otherwise fill with empty space.
    @Test func keepsTheSheetWidthAndFitsItsHeight() {
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let sheet = NameSheet.newTerminal(project: project, suggestedName: "Terminal", branch: "main",
                                          canCreate: true, createTerminal: { _ in })
        let host = NSHostingView(rootView: sheet)

        #expect(host.fittingSize.width == Sheet.width)
        #expect(host.fittingSize.height < Sheet.fittingHeight(Sheet.height))
        #expect(host.fittingSize.height > 0)
    }
}
