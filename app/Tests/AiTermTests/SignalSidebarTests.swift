import Foundation
import AppKit
import SwiftUI
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalSidebarTests {
    @Test func headingsHoldTheSameTaskRowsAndTakeoverReturnsTheTaskToItsProject() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let entries = SidebarModel.entries(state: world.state, sessions: [], branchByCwd: [:], projectBranch: [:])
        let sidebar = SignalSidebar(state: world.state, entries: entries)
        #expect(sidebar.signals.count == 1)
        #expect(sidebar.signals[0].tasks.map(\.id) == [id])
        let ordinary: [TaskRow] = sidebar.projects.flatMap { entry -> [TaskRow] in
            if case .project(let section) = entry { return section.tasks }; return []
        }
        #expect(ordinary.isEmpty)
        world.state.updateSignalTask(id) { $0.takenOver = true }
        let taken = SignalSidebar(state: world.state, entries: entries)
        #expect(taken.signals[0].tasks.isEmpty)
        let projectTasks: [UUID] = taken.projects.flatMap { entry -> [UUID] in
            if case .project(let section) = entry { return section.tasks.map(\.id) }; return []
        }
        #expect(projectTasks == [id])
    }
    @Test func theOperatorRowExistsAndCanBeSelectedBeforeItsFirstSession() throws {
        let folder = try ScratchFolder.make("aiterm-signal-sidebar-"); defer { try? FileManager.default.removeItem(at: folder) }
        let controller = AppController(store: StateStore(url: folder.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        #expect(controller.focus.row(id: OperatorRow.id(of: OperatorSession.rowID)) == .operation(OperatorSession.rowID))
        #expect(controller.rows.signalSections.isEmpty)
    }
    @Test func thePermanentRowAndSignalHeadersLeaveProjectsVisible() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 420, height: 600))
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows == 4 }
        let list = try #require(host.firstDescendant(NSTableView.self))
        #expect(list.numberOfRows == 4, "Operator heading, permanent row, Projects heading and empty state")
        var world = SignalWorld(); _ = world.signal(); _ = world.workingTask(signal: world.state.signals[0].id)
        controller.workspace.mutate { $0 = world.state }
        settle(host) { list.numberOfRows == 6 }
        #expect(list.numberOfRows == 6, "A signal holds its task while its project remains visible")
        controller.toggleCollapsed(world.state.signals[0])
        settle(host) { list.numberOfRows == 5 }
        #expect(list.numberOfRows == 5)
        controller.toggleCollapsed(world.state.signals[0])
        settle(host) { list.numberOfRows == 6 }
        #expect(list.numberOfRows == 6)
    }
}
