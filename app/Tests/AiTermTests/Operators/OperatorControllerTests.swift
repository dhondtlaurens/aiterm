import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// An operation's start and the operator's own tab (spec §4.0.1, §5, §11).
@MainActor @Suite struct OperatorControllerTests {
    let project = OperatorServiceFixtures.project()

    @Test func startingABroadcastSavesItRegistersItsTokenAndOpensTheOperatorInFront() async throws {
        var profile = OperatorServiceFixtures.profile(oracle: true)
        profile.slices.jira = true
        let saved = profile
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [])) { $0.profile = { saved } }
        let id = try await world.controller.startBroadcast(name: "  ", jiraProjectKeys: ["PLUTO"], projectIds: [project.id],
                                                           prompt: "Implement PLUTO-1 and PLUTO-2.\nThen tidy.", review: "  ",
                                                           done: "a commit per ticket")
        let run = try #require(world.run(id))
        #expect(run.name == "Implement PLUTO-1 and PLUTO-2.", "no name given: the prompt's first line")
        #expect(run.state == .planning && run.projectIds == [project.id] && run.done == "a commit per ticket")
        #expect(run.jiraProjectKeys == ["PLUTO"])
        #expect(run.profile == profile, "Settings › Operator's profile, frozen in the run")
        #expect(run.review == nil, "a blank Review is none")
        #expect(run.planRevision == 0)
        let folder = OperatorCommand.runFolder(id, home: world.ports.home)
        let register = try #require(world.daemon.requests("operator.register").first)
        #expect(register.params["runId"] as? String == id.uuidString)
        #expect(register.params["token"] as? String == OperatorCommand.existingToken(in: folder))
        let firstMessage = try String(contentsOf: folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)
        #expect(firstMessage == "Your broadcast:\n\nImplement PLUTO-1 and PLUTO-2.\nThen tidy.\n\nDone: a commit per ticket")
        let window = try #require(world.daemon.requests("window.createTask").first)
        #expect(window.params["taskId"] as? String == id.uuidString)
        #expect(window.params["cwd"] as? String == folder.path)
        #expect(window.params["background"] == nil)
        #expect((window.params["agentCommand"] as? String)?.hasPrefix("claude") == true)
        #expect(run.operatorWindowId == "reopened")
        #expect(world.notifications.authorizationRequests == 1)
        #expect(try world.workspace.file.load().runs.map(\.id) == [id])
    }

    @Test func aBroadcastNeedsAPromptAndProjectsOfThisWorkspace() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []))
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "  ", review: nil, done: nil)
        }
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [UUID()], prompt: "Go", review: nil, done: nil)
        }
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [], prompt: "Go", review: nil, done: nil)
        }
        world.link.attached = false
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
        #expect(world.state.runs.isEmpty)
        #expect(world.daemon.requests.isEmpty)
    }

    /// The Jira projects of a broadcast's projects, by key: each once, in the order the projects list them.
    @Test func theJiraKeysAreTheProjectsLinkedOnesEachOnce() {
        let site = URL(string: "https://acme.atlassian.net")!
        let shop = OperatorServiceFixtures.project(name: "Shop", jira: [JiraProjectRef(id: "1", key: "PLUTO", name: "Pluto", siteURL: site),
                                                                       JiraProjectRef(id: "2", key: "SHOP", name: "Shop", siteURL: site)])
        let blog = OperatorServiceFixtures.project(name: "Blog", jira: [JiraProjectRef(id: "3", key: "BLOG", name: "Blog", siteURL: site),
                                                                       JiraProjectRef(id: "1", key: "PLUTO", name: "Pluto", siteURL: site)])
        let none = OperatorServiceFixtures.project(name: "None")
        let state = OperatorServiceFixtures.state(projects: [shop, blog, none], runs: [])
        #expect(OperatorController.jiraKeys(of: [shop.id, blog.id], in: state) == ["PLUTO", "SHOP", "BLOG"])
        #expect(OperatorController.jiraKeys(of: [blog.id, shop.id], in: state) == ["BLOG", "PLUTO", "SHOP"])
        #expect(OperatorController.jiraKeys(of: [none.id, UUID()], in: state).isEmpty, "a project with none, and one not in the workspace")
    }

    @Test func theOperatorsTaggedTabGivesTheRunItsSessionWindowAndConversation() throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        world.show([OperatorServiceFixtures.session("op", window: "w7", tag: run.id, conversation: "c-123")])
        let saved = try #require(world.run(run.id))
        #expect(saved.operatorSessionId == "op" && saved.operatorWindowId == "w7" && saved.operatorConversation == "c-123")
        #expect(world.controller.operatorTab(of: run.id)?.sessionId == "op")
    }

    @Test func aDaemonAttachingReregistersEveryTokenButAStoppedRunsAndSaysItReconnected() async throws {
        let active = OperatorServiceFixtures.run(projects: [project], state: .active), stopped = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [active, stopped]))
        let tokens = [active.id: String(repeating: "a", count: 64), stopped.id: String(repeating: "b", count: 64)]
        for run in [active, stopped] {
            _ = try OperatorCommand.prepare(run: run, projects: [project], home: world.ports.home, token: tokens[run.id]!)
        }
        world.show([OperatorServiceFixtures.session("op", tag: active.id)])
        world.controller.daemonAttached()
        await world.controller.registering?.value
        #expect(world.daemon.requests("operator.register").map { $0.params["runId"] as? String } == [active.id.uuidString])
        #expect(world.daemon.requests("operator.register").first?.params["token"] as? String == tokens[active.id])
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").first?.params["text"] as? String == "[AiTerm] reconnected, call run_status")
    }

    @Test func anOperationWorksInTheProjectsItsBriefsTicketsBelongTo() {
        let pluto = OperatorServiceFixtures.project(name: "Pluto", jira: [JiraProjectRef(id: "1", key: "PLUTO", name: "Pluto",
                                                                                 siteURL: URL(string: "https://acme.atlassian.net")!)])
        let other = OperatorServiceFixtures.project(name: "Other")
        let state = OperatorServiceFixtures.state(projects: [pluto, other], runs: [])
        #expect(OperatorController.projects(for: "Do pluto-12 and PLUTO-13.", in: state) == [pluto.id])
        #expect(OperatorController.projects(for: "Tidy the docs.", in: state) == [pluto.id, other.id])
    }

    @Test func aRunChangingIsHeardOnceAndAnUnrelatedChangeNotAtAll() throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        var heard = 0
        world.controller.onChange { heard += 1 }
        world.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 10, height: 10) }
        world.controller.mutateRun(run.id) { $0.name = "Renamed" }
        #expect(heard == 1)
        world.controller.setActing(UUID(), true)
        #expect(heard == 2)
    }

    @Test func anOperationIsNamedFromItsBriefsFirstLine() {
        #expect(OperatorController.operationName(from: "\n  Fix the login bug  \nmore") == "Fix the login bug")
        #expect(OperatorController.operationName(from: String(repeating: "a", count: 80)) == String(repeating: "a", count: 47) + "…")
    }

    /// The operator's window closed (spec §9): the run forgets the window and session, and the broadcast goes
    /// offline, a complete one included: nothing ends, and a click on its row reopens it. A tab not yet seen,
    /// or tabs not known while iTerm2 is away, close nothing.
    @Test func closingTheOperatorsWindowForgetsItAndTakesTheBroadcastOffline() async throws {
        let active = OperatorServiceFixtures.run(projects: [project], state: .active)
        let complete = OperatorServiceFixtures.run(projects: [project], state: .complete)
        var opening = OperatorServiceFixtures.run(projects: [project], state: .planning)
        opening.operatorWindowId = "w-new"
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [active, complete, opening]))
        world.show([OperatorServiceFixtures.session("op1", window: "w1", tag: active.id),
                    OperatorServiceFixtures.session("op2", window: "w2", tag: complete.id)])
        world.controller.handle(.itermDisconnected)
        world.live.sessions = []
        world.controller.handle(.windowClosed("w1"))
        #expect(world.run(active.id)?.operatorWindowId == "w1", "iTerm2 away: its tabs are not known gone")
        world.show([])
        #expect(world.run(active.id)?.operatorWindowId == nil && world.run(active.id)?.operatorSessionId == nil)
        #expect(world.run(active.id)?.state == .operatorOffline && world.run(active.id)?.intent == nil)
        #expect(world.run(opening.id)?.operatorWindowId == "w-new", "a window whose tab was never seen may still be opening")
        #expect(world.run(complete.id)?.state == .operatorOffline && world.run(complete.id)?.intent == nil, "the debrief stays until End")
        #expect(world.daemon.requests("operator.revoke").isEmpty)
    }

    /// A notification's click on an overview (spec §10.3) is for the sidebar to present: it reads
    /// `presentOverview` and clears it.
    @Test func aNotificationsClickOnAnOverviewAsksTheSidebarToPresentIt() {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        let id = UUID()
        controller.openNote(.overview(id))
        #expect(controller.operatorController.presentOverview == id)
    }

    /// News that came while the run was paused is not lost: the wake line goes when it resumes.
    @Test func aPausedRunsWakeNewsGoesWhenItResumes() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .paused)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.workspace.mutate { $0.tasks.append(OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1")) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(world.daemon.requests("session.deliver").isEmpty, "a paused run's operator is not woken")
        world.controller.mutateRun(run.id) { $0.state = .active }
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").first?.params["text"] as? String == "[AiTerm] 2 updates, call run_status")  // the task, and the resuming itself
    }

    // -- a start that fails leaves nothing behind -----------------------------------------------
    private func startFailing(_ world: OperatorWorld) async {
        await #expect(throws: (any Error).self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
    }

    /// The folder a failed start wrote: its token file is gone, its brief stays.
    private func expectTokenDiscarded(_ world: OperatorWorld) throws {
        let parent = OperatorCommand.runFolder(UUID(), home: world.ports.home).deletingLastPathComponent()
        let folder = try #require(try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(OperatorCommand.tokenFile).path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(OperatorCommand.briefFile).path))
    }

    private func expectNoRun(_ world: OperatorWorld) throws {
        #expect(world.state.runs.isEmpty)
        #expect(try world.workspace.file.load().runs.isEmpty)
    }

    @Test func aFailingSaveTakesTheRunBackOutAndRegistersNothing() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []))
        #expect(world.workspace.flush())
        let backup = world.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        await startFailing(world)
        #expect(world.state.runs.isEmpty)
        #expect(world.daemon.requests("operator.register").isEmpty && world.daemon.requests("window.createTask").isEmpty)
        try expectTokenDiscarded(world)
    }

    @Test func aFailingRegisterTakesTheRunBackOutAndOpensNoWindow() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []),
                                      daemon: RecordingDaemon(failing: ["operator.register": "temporary_failure"]))
        await startFailing(world)
        try expectNoRun(world)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        try expectTokenDiscarded(world)
    }

    @Test func aFailingWindowTakesTheRunBackOutAndRevokesItsToken() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []),
                                      daemon: RecordingDaemon(failing: ["window.createTask": "temporary_failure"]))
        await startFailing(world)
        try expectNoRun(world)
        try expectTokenDiscarded(world)
        let registered = try #require(world.daemon.requests("operator.register").first?.params["runId"] as? String)
        #expect(world.daemon.requests("operator.revoke").map { $0.params["runId"] as? String } == [registered])
    }

    @Test func aDaemonAttachingRevokesTheTokenOfARunYouEndedWhileItsTokenFileIsThere() async throws {
        let ended = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let gone = OperatorServiceFixtures.run(projects: [project], state: .complete)
        var endedByYou = ended, goneByYou = gone
        endedByYou.intent = .stopped
        goneByYou.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [endedByYou, goneByYou]))
        _ = try OperatorCommand.prepare(run: endedByYou, projects: [project], home: world.ports.home, token: String(repeating: "c", count: 64))
        world.controller.daemonAttached()
        await world.controller.registering?.value
        #expect(world.daemon.requests("operator.revoke").map { $0.params["runId"] as? String } == [endedByYou.id.uuidString])
        #expect(world.daemon.requests("operator.register").isEmpty)
    }

    @Test func aNotificationOverviewWaitsForTheRenameSheetToDismiss() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorServiceFixtures.run(projects: [project])
        controller.workspace.mutate { $0.runs = [run] }
        controller.sheet = .rename(.operation(run))
        controller.openNote(.overview(run.id))
        controller.presentRequestedOverview()
        #expect(controller.sheet?.id == "rename-\(run.id)")
        #expect(controller.operatorController.presentOverview == run.id)
        controller.sheets.sheet = nil
        guard case .operationOverview(let id)? = controller.sheet else { Issue.record("No deferred overview"); return }
        #expect(id == run.id)
        #expect(controller.operatorController.presentOverview == nil)
        controller.sheet = nil
        #expect(controller.sheet == nil)
    }

    @Test func aDeferredOverviewForARemovedRunClearsSilently() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorServiceFixtures.run(projects: [project])
        controller.workspace.mutate { $0.runs = [run] }
        controller.sheet = .newDivider
        controller.openNote(.overview(run.id))
        controller.presentRequestedOverview()
        #expect(controller.operatorController.presentOverview == run.id)
        controller.workspace.mutate { $0.runs = [] }
        controller.sheets.sheet = nil
        #expect(controller.sheet == nil)
        #expect(controller.operatorController.presentOverview == nil)
    }
}
