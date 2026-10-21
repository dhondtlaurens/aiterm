import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// New Broadcast as a model (spec §3.1): the name, the Jira projects and the projects on step 1, the
/// prompt, review and done on the next three, the help the slices decide, and Start Broadcast
/// handing them to `OperatorController.startBroadcast`.
@MainActor
struct NewBroadcastModelTests {
    private static let site = URL(string: "https://pauwels.atlassian.net")!
    private let pay = JiraProjectRef(id: "10001", key: "PAY", name: "Payments", siteURL: Self.site)
    private let shop = JiraProjectRef(id: "10002", key: "SHOP", name: "Webshop", siteURL: Self.site)

    private func project(_ name: String, jira: [JiraProjectRef] = []) -> Project {
        Project(id: UUID(), name: name, path: "/tmp/\(name)", provider: .gitlab, remoteUrl: nil, addedAt: Date(),
                collapsed: false, jiraProjects: jira)
    }

    private func model(projects: [Project] = [], slices: Slices = .none,
                       start: @escaping @MainActor (NewBroadcastModel.Request) async throws -> UUID = { _ in UUID() }) -> NewBroadcastModel {
        NewBroadcastModel(projects: projects, slices: slices, start: start)
    }

    @Test func itNamesItsStepsAndWhereItOpens() {
        #expect(NewBroadcastModel.title == "New broadcast")
        #expect(NewBroadcastModel.stepNames == ["Broadcast", "Prompt", "Review", "Done"])
        #expect(NewBroadcastModel.destination.text == "Opens in iTerm2 · the Operator’s window")
        #expect(NewBroadcastModel.namePlaceholder == "Named by the Operator from the prompt")
        #expect(NewBroadcastModel.nameHelp == "Optional.")
        #expect(NewBroadcastModel.jiraProjectsHelp == "Where it reads tickets, and files them with the Jira slice on.")
        #expect(NewBroadcastModel.projectsHelp == "The repositories it may work in. Picking a Jira project adds its linked projects.")
        #expect(NewBroadcastModel.promptHelp == "What to work on, as you’d tell a colleague. A Jira key brings in its ticket. Type / for skills, @ for files.")
        #expect(NewBroadcastModel.reviewPlaceholder == "An adversarial review with /code-review, then fix what it finds")
        #expect(NewBroadcastModel.donePlaceholder == "A draft MR per ticket")
    }

    @Test func needsAProjectAndAPrompt() async {
        var started = 0
        let webshop = project("webshop")
        let sheet = model(projects: [webshop]) { _ in started += 1; return UUID() }
        #expect(!sheet.canAdvance(step: 1), "no project yet")
        sheet.add(project: webshop)
        #expect(sheet.canAdvance(step: 1))
        #expect(!sheet.canAdvance(step: 2), "no prompt yet")
        sheet.prompt = "  \n "
        #expect(!sheet.canAdvance(step: 2), "whitespace is no prompt")
        #expect(!sheet.canStart)
        #expect(await sheet.start() == nil)
        #expect(started == 0)
        sheet.prompt = "Implement PAY-230 to PAY-236"
        #expect(sheet.canAdvance(step: 2) && sheet.canAdvance(step: 3) && sheet.canAdvance(step: 4))
        #expect(sheet.canStart)
        sheet.remove(project: webshop)
        #expect(!sheet.canAdvance(step: 1) && !sheet.canStart, "the last project removed")
    }

    @Test func jiraProjectAddsItsLinkedProjects() {
        let webshop = project("webshop", jira: [shop, pay]), api = project("payments-api", jira: [pay]), blog = project("blog")
        let sheet = model(projects: [webshop, api, blog])
        #expect(sheet.offeredJiraProjects == [shop, pay], "every linked Jira project, each once")
        sheet.add(jiraProject: pay)
        #expect(sheet.jiraProjects == [pay])
        #expect(sheet.projects == [webshop, api], "in the sidebar's order")
        sheet.add(jiraProject: shop)
        #expect(sheet.jiraProjects == [pay, shop])
        #expect(sheet.projects == [webshop, api], "a project already picked is not picked twice")
        sheet.add(jiraProject: pay)
        #expect(sheet.jiraProjects == [pay, shop])
        sheet.remove(jiraProject: pay)
        #expect(sheet.jiraProjects == [shop])
        #expect(sheet.projects == [webshop, api], "removing a Jira project keeps the projects it added")
        sheet.add(project: blog)
        sheet.add(project: blog)
        #expect(sheet.projects == [webshop, api, blog])
        #expect(sheet.matchingProjects(query: "") == [], "nothing left to add")
        sheet.remove(project: api)
        #expect(sheet.matchingProjects(query: "pay") == [api])
        #expect(sheet.matchingJiraProjects(query: "pay") == [pay])
    }

    /// The picker offers the connection's Jira projects, as the Jira projects sheet fetches them, the
    /// ones the sidebar's projects link first; picking one still picks its linked projects.
    @Test func theJiraPickerOffersTheConnectionsProjectsLinkedOnesFirst() async {
        let ops = JiraProjectRef(id: "10003", key: "OPS", name: "Operations", siteURL: Self.site)
        let web = JiraProjectRef(id: "10004", key: "WEB", name: "Website", siteURL: Self.site)
        let webshop = project("webshop", jira: [shop, pay]), api = project("payments-api", jira: [pay])
        let sheet = NewBroadcastModel(projects: [webshop, api], slices: .none, loadJiraProjects: { [ops, pay, web, shop] },
                                      start: { _ in UUID() })
        #expect(sheet.jiraLoad == .loading)
        #expect(sheet.jiraStatus == "Loading Jira projects…")
        #expect(sheet.offeredJiraProjects == [shop, pay], "the linked ones while Jira answers")
        await sheet.loadJiraProjects()
        #expect(sheet.jiraLoad == .loaded && sheet.jiraStatus == nil)
        #expect(sheet.offeredJiraProjects == [shop, pay, ops, web], "linked first, then the rest in Jira's order, each once")
        #expect(sheet.matchingJiraProjects(query: "") == [shop, pay, ops, web])
        #expect(sheet.matchingJiraProjects(query: "web") == [web, shop], "a key match before a name match")
        #expect(sheet.matchingJiraProjects(query: "oper") == [ops])
        sheet.add(jiraProject: ops)
        #expect(sheet.projects.isEmpty, "a Jira project no project links picks none")
        sheet.add(jiraProject: pay)
        #expect(sheet.projects == [webshop, api])
        #expect(sheet.matchingJiraProjects(query: "") == [shop, web], "what is picked is not offered again")
    }

    @Test func aConnectionWithNoJiraProjectsSaysSo() async {
        let sheet = NewBroadcastModel(projects: [project("blog")], slices: .none, loadJiraProjects: { [] }, start: { _ in UUID() })
        await sheet.loadJiraProjects()
        #expect(sheet.offeredJiraProjects.isEmpty)
        #expect(sheet.jiraStatus == "No Jira projects found.")
    }

    /// Jira away, or not connected: the linked ones stay on offer, the help says so, and Start isn't held up.
    @Test func aJiraThatCantBeReachedKeepsTheLinkedOnesAndDoesNotBlockStart() async {
        let webshop = project("webshop", jira: [pay])
        let sheet = NewBroadcastModel(projects: [webshop], slices: .none,
                                      loadJiraProjects: { throw ActionUnavailable("The connection dropped.") }, start: { _ in UUID() })
        await sheet.loadJiraProjects()
        #expect(sheet.jiraLoad == .failed("The connection dropped."))
        #expect(sheet.offeredJiraProjects == [pay])
        #expect(sheet.jiraStatus == "The connection dropped. Only the Jira projects your projects link are offered.")
        sheet.add(jiraProject: pay)
        sheet.prompt = "PAY-230"
        #expect(sheet.canStart)
        #expect(await sheet.start() != nil)
    }

    /// Jira not connected says why, in the words the Jira projects sheet shows, not that Jira couldn’t be reached.
    @Test func jiraNotConnectedSaysToConnectIt() async {
        let reason = "Connect Jira in Settings › Integrations to choose a Jira project."
        let linked = NewBroadcastModel(projects: [project("webshop", jira: [pay])], slices: .none,
                                       loadJiraProjects: { throw ActionUnavailable(reason) }, start: { _ in UUID() })
        await linked.loadJiraProjects()
        #expect(linked.jiraStatus == reason + " Only the Jira projects your projects link are offered.")
        let none = NewBroadcastModel(projects: [project("blog")], slices: .none,
                                     loadJiraProjects: { throw ActionUnavailable(reason) }, start: { _ in UUID() })
        await none.loadJiraProjects()
        #expect(none.jiraStatus == reason, "with no linked project there is nothing to offer, so nothing to add")
    }

    /// As New Task's: nothing moves on while the workspace can't change.
    @Test func itWaitsForAWorkspaceThatCanChange() {
        let canChange = Mutex(false)
        let webshop = project("webshop")
        let sheet = NewBroadcastModel(projects: [webshop], slices: .none, canChangeWorkspace: { canChange.withLock { $0 } }, start: { _ in UUID() })
        sheet.add(project: webshop)
        sheet.prompt = "PAY-230"
        #expect(!sheet.canAdvance(step: 1) && !sheet.canStart)
        canChange.withLock { $0 = true }
        #expect(sheet.canAdvance(step: 1) && sheet.canStart)
    }

    @Test func helpFollowsTheSlices() {
        let off = model(slices: .none), on = model(slices: Slices(jira: false, review: true, merge: true))
        #expect(on.reviewHelp == "Who reviews each task and how. Optional. An agent review (“an adversarial review with /code-review”) needs no switch; involving people needs Review, which is on in Settings › Operator.")
        #expect(off.reviewHelp == "Who reviews each task and how. Optional. An agent review needs no switch. Review is off in Settings › Operator, so the Operator won’t involve people: those tasks stop at their draft MR.")
        #expect(on.doneHelp == "Where each task ends: a commit, a draft MR, or merged and when. Write a condition per MR: “each MR merges once approved with all threads resolved; the run is done when every MR is merged”. Before a merge, the Oracle checks what the Review asks of an agent review against the review of the accepted commit. Optional: left empty, each task ends at a draft MR.")
        #expect(off.doneHelp == "Where each task ends. Optional: left empty, each task ends at a draft MR. Merge is off in Settings › Operator: each task ends at a commit or a draft MR, and a merge you ask for is left for you.")
        let reviewOnly = model(slices: Slices(review: true))
        #expect(reviewOnly.reviewHelp == on.reviewHelp && reviewOnly.doneHelp == off.doneHelp, "each help reads its own slice")
        let copy = [on.reviewHelp, off.reviewHelp, on.doneHelp, off.doneHelp, NewBroadcastModel.promptHelp,
                    NewBroadcastModel.projectsHelp, NewBroadcastModel.jiraProjectsHelp, NewBroadcastModel.destination.text]
        for text in copy {
            #expect(!text.contains("—"), "no em dash in \(text)")
            #expect(!text.contains("'"), "the app's curly apostrophe in \(text)")
        }
    }

    @Test func startHandsTheBroadcastToTheController() async {
        var requests: [NewBroadcastModel.Request] = []
        let id = UUID()
        let webshop = project("webshop", jira: [pay]), api = project("payments-api")
        let sheet = model(projects: [webshop, api]) { requests.append($0); return id }
        sheet.add(jiraProject: pay)
        sheet.add(project: api)
        sheet.name = "   "
        sheet.prompt = "  Implement PAY-230 to PAY-236\n"
        sheet.review = "Assign Jan. "
        sheet.done = " \n"
        #expect(await sheet.start() == id)
        #expect(requests == [NewBroadcastModel.Request(name: nil, jiraProjectKeys: ["PAY"], projectIds: [webshop.id, api.id],
                                                         prompt: "Implement PAY-230 to PAY-236", review: "Assign Jan.", done: nil)])
        sheet.name = " Checkout redesign "
        _ = await sheet.start()
        #expect(requests.last?.name == "Checkout redesign")
    }

    /// Every kind of text a person types (`TypedText`) reaches the controller byte for byte: only its
    /// ends are trimmed, and these texts have nothing to trim.
    @Test func everyKindOfTypedTextReachesTheControllerWhole() async throws {
        var requests: [NewBroadcastModel.Request] = []
        let webshop = project("webshop")
        let sheet = model(projects: [webshop]) { requests.append($0); return UUID() }
        sheet.add(project: webshop)
        sheet.prompt = TypedText.text("Prompt", bytes: 110_000)
        sheet.review = TypedText.text("Review")
        sheet.done = TypedText.text("Done")

        _ = await sheet.start()

        let request = try #require(requests.first)
        #expect(Array(request.prompt.utf8) == Array(sheet.prompt.utf8))
        #expect(request.review.map { Array($0.utf8) } == Array(sheet.review.utf8))
        #expect(request.done.map { Array($0.utf8) } == Array(sheet.done.utf8))
    }

    @Test func aStartThatFailsSaysWhyInTheFooterAndCanBeTriedAgain() async {
        struct Refused: LocalizedError { var errorDescription: String? { "One broadcast at a time." } }
        let webshop = project("webshop")
        let sheet = model(projects: [webshop]) { _ in throw Refused() }
        sheet.add(project: webshop)
        sheet.prompt = "PAY-230"
        #expect(await sheet.start() == nil)
        #expect(sheet.error?.reason == "One broadcast at a time.")
        #expect(!sheet.starting && sheet.canStart)
    }

    /// A start held open: a second press, or ⌘↩ while it is in flight, must not start a second broadcast.
    @Test func aSecondPressWhileAStartIsInFlightStartsNothingMore() async {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var enteredStarts = entered.makeAsyncIterator()
        let id = UUID(), webshop = project("webshop")
        let sheet = model(projects: [webshop]) { _ in
            calls += 1
            signal.yield()
            await withCheckedContinuation { release = $0 }
            return id
        }
        sheet.add(project: webshop)
        sheet.prompt = "PAY-230"
        let first = Task { await sheet.start() }
        await enteredStarts.next()
        #expect(sheet.starting && !sheet.canStart && !sheet.canAdvance(step: 4))
        #expect(await sheet.start() == nil, "pressed again while the first is in flight")
        #expect(calls == 1)
        release?.resume()
        #expect(await first.value == id)
        #expect(calls == 1 && !sheet.starting)
    }

    /// The OPERATOR heading's "+" opens it on the sidebar's projects, and on nothing while the workspace can't change.
    @Test func theHeadingsPlusOpensIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let webshop = project("webshop", jira: [pay])
        controller.workspace.mutate { $0.items = [.project(webshop)] }
        controller.presentNewBroadcast()
        #expect(await eventually(describing: "New Broadcast opens") { controller.sheet != nil })
        guard case .newBroadcast(let sheet)? = controller.sheet else { Issue.record("no New Broadcast sheet"); return }
        #expect(sheet.offeredProjects == [webshop])
        #expect(sheet.offeredJiraProjects == [pay])
        #expect(controller.sheet?.id == "broadcast-new-\(sheet.id)")
    }

    /// `/` lists both agents' skills, each once, from the picked projects as well as the home.
    @Test func slashListsBothAgentsSkills() async {
        let webshop = project("webshop")
        let path = webshop.path
        let sheet = NewBroadcastModel(projects: [webshop], slices: .none, skills: { agent, at in
            @Sendable func skill(_ name: String) -> AgentCompletion { AgentCompletion(name: name, kind: .skill, detail: nil, source: .user) }
            return switch agent {
            case .claude: [skill("superpowers:brainstorming"), skill("code-review")] + (at == path ? [skill("deploy")] : [])
            case .codex: [skill("code-review"), skill("imagegen")]
            default: [skill("never")]
            }
        }, start: { _ in UUID() })
        await sheet.loadCompletions()
        #expect(sheet.completions.all.map(\.name) == ["superpowers:brainstorming", "code-review", "imagegen"])
        sheet.add(project: webshop)
        await sheet.loadCompletions()
        #expect(sheet.completions.all.map(\.name) == ["superpowers:brainstorming", "code-review", "deploy", "imagegen"])
    }
}

extension NewBroadcastModelTests {
    @Test func openingNewBroadcastReadsTheBlockingProfileOffMain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mainReads = MainThreadReadings()
        var ports = OperatorPorts.scratch()
        ports.profile = {
            mainReads.append(Thread.isMainThread)
            return OperatorProfile(model: "opus", reasoning: nil)
        }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(), operatorPorts: ports)
        try controller.loadWorkspace()
        controller.presentNewBroadcast()
        #expect(await eventually(describing: "New Broadcast opens after profile read") { controller.sheet != nil })
        #expect(mainReads.all == [false])
    }
}

private final class MainThreadReadings: Sendable {
    private let readings = Mutex<[Bool]>([])
    func append(_ value: Bool) { readings.withLock { $0.append(value) } }
    var all: [Bool] { readings.withLock { $0 } }
}

extension NewBroadcastModelTests {
    /// `/` lists Claude's skills from the folder the login shell's `CLAUDE_CONFIG_DIR` names.
    @Test func slashListsClaudesSkillsFromTheConfiguredFolder() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for (folder, name) in [(".claude", "wrong-folder"), ("profile", "moved")] {
            let skill = home.appendingPathComponent("\(folder)/skills/\(name)/SKILL.md")
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: A skill\n---\nBody\n".write(to: skill, atomically: true, encoding: .utf8)
        }
        let controller = AppController(store: StateStore(url: home.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, claudeConfig: ClaudeConfig("~/profile"))
        try controller.loadWorkspace()
        controller.presentNewBroadcast()
        #expect(await eventually(describing: "New Broadcast opens") { controller.sheet != nil })
        guard case .newBroadcast(let sheet)? = controller.sheet else { Issue.record("no New Broadcast sheet"); return }
        await sheet.loadCompletions()
        let names = sheet.completions.all.map(\.name)
        #expect(names.contains("moved") && !names.contains("wrong-folder"))
    }
}
