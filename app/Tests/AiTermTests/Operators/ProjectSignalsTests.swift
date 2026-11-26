import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// A project signal's pick-up, through the controller's own entry points: a pass decides it, its project's runner makes
/// the task (a scripted create that saves as the launcher does) and opens its window behind, in the person's pause. No
/// Operator chat, stage or activity record is involved.
@Suite @MainActor struct ProjectSignalsTests {
    /// A GitLab reviewer match is an ordinary review row in its project, marked with its signal and owing nothing once its
    /// window opened. The Operator has no work, no chat is opened and nothing reaches the helper for it.
    @Test func aGitLabReviewerMatchMakesAnOrdinaryReviewRowWithAnOrigin() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()

        rig.pass(signal, [Self.request(7, description: "Retries need a key.")], accountUser: "alex")
        await rig.settled()

        let request = try #require(rig.requests.first)
        guard case .review(let draft) = request.kind else { Issue.record("A review, not \(request.kind)."); return }
        #expect(draft.mr?.iid == 7 && draft.agent == SignalWorld.agent.agent && draft.model == SignalWorld.agent.model)
        #expect(draft.promptText == "/psg:peer-review")
        let task = try #require(rig.state.tasks.first)
        #expect(task.kind == .review && task.signalTask == nil)
        #expect(task.signalOrigin?.signal == signal && task.signalOrigin?.owed == nil && task.signalOrigin?.turn?.sentAt == world.now)
        #expect(rig.opens.map(\.id) == [task.id])
        #expect(rig.state.signalSeen.map(\.disposition) == [.started])
        #expect(!rig.state.operatorHasWork && rig.state.operatorSession == nil)
        #expect(rig.daemon.requests("operator.register").isEmpty && rig.daemon.requests("window.createTask").isEmpty)
        #expect(Self.activity(rig).isEmpty, "A pick-up writes nothing to the Operator's activity log.")
    }

    /// The prompt is composed once, from the signal's bare prompt and its description switches: the descriptions'
    /// envelope appears once, never twice.
    @Test func theDescriptionEnvelopeAppearsOnce() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()

        rig.pass(signal, [Self.request(7, description: "Retries need a key.")], accountUser: "alex")
        await rig.settled()

        let prompt = try #require(rig.opens.first?.prompt)
        #expect(prompt.hasPrefix("/psg:peer-review\n\n"))
        #expect(prompt.components(separatedBy: "untrusted item descriptions").count == 2)
        #expect(prompt.components(separatedBy: "Retries need a key.").count == 2)
    }

    /// A request from a fork is skipped with the fork's reason before any checkout, even with an upstream branch's name.
    @Test func aForkedRequestIsSkippedWithTheForkReasonAndMakesNoCheckout() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()

        rig.pass(signal, [Self.request(7, source: "main", fork: "someone/web:main")], accountUser: "alex")
        await rig.settled()

        #expect(rig.requests.isEmpty && rig.state.tasks.isEmpty)
        #expect(rig.state.signalSeen.map(\.reason) == [MatchDecision.fromFork])
        #expect(Self.activity(rig).isEmpty, "A project signal's skip is not the Operator's.")
    }

    /// A create that throws leaves the item's skip with its reason; the next pass waits out the back-off and then makes it.
    @Test func aThrowingCreateIsSkippedWithItsReasonAndTheNextPassAfterTheBackOffSucceeds() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.failures = [ActionUnavailable("git refused the branch.")]

        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.state.tasks.isEmpty)
        #expect(rig.state.signalSeen.map(\.reason) == ["Couldn’t start its task: git refused the branch."])
        #expect(rig.root.projectSignals.claimed == [world.ticket().item.identity!])
        rig.clock.advance(by: 60)
        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.requests.count == 1, "Backing off.")

        rig.clock.advance(by: SignalPoller.failureBackOff)
        await rig.root.reconcile()
        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.requests.count == 2 && rig.state.tasks.count == 1)
        #expect(rig.state.signalSeen.map(\.disposition) == [.started] && rig.state.signalSeen.first?.reason == nil)
    }

    /// A project busy creating (the person's create) puts the pick-up back without counting a failure; the next tick
    /// makes it.
    @Test func aBusyProjectPutsThePickUpBackForTheNextTick() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.failures = [CreationBusy(project: "shop")]

        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.state.tasks.isEmpty && rig.state.signalSeen.isEmpty, "Nothing recorded for a busy project.")
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.requests.count == 2 && rig.state.tasks.count == 1)
    }

    /// Two matches in one project queue: the second create starts only once the first is done.
    @Test func twoMatchesInOneProjectQueue() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        let entered = TestLatch(), release = TestLatch()
        rig.hold = (entered, release)

        rig.pass(signal, [world.ticket("PAY-1"), world.ticket("PAY-2")])
        await entered.wait()
        #expect(rig.requests.count == 1)
        #expect(rig.root.projectSignals.claimed == Set(["PAY-1", "PAY-2"].map { world.ticket($0).item.identity! }))
        rig.hold = nil; release.signal()
        await rig.settled()
        #expect(rig.state.tasks.map(\.title) == ["Make retries safe", "Make retries safe"])
        #expect(rig.state.tasks.compactMap(\.signalOrigin?.item.identity) == ["PAY-1", "PAY-2"].map { world.ticket($0).item.identity! })
        #expect(rig.opens.count == 2)
    }

    /// While queued, a pick-up is dropped when a full read no longer lists its item, or its signal is switched off.
    @Test func aQueuedPickUpIsDroppedWhenItsItemLeavesOrItsSignalIsSwitchedOff() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        let entered = TestLatch(), release = TestLatch()
        rig.hold = (entered, release)

        rig.pass(signal, [world.ticket("PAY-1"), world.ticket("PAY-2"), world.ticket("PAY-3")])
        await entered.wait()
        rig.pass(signal, [world.ticket("PAY-1"), world.ticket("PAY-3")])
        rig.workspace.mutate { $0.signals[0].enabled = false }
        rig.hold = nil; release.signal()
        await rig.settled()

        #expect(rig.requests.count == 1, "PAY-2 left the read and PAY-3's signal is off.")
        #expect(rig.state.tasks.count == 1)
    }

    /// While queued, a pick-up is dropped when its signal no longer reads items from the same source, or the item's
    /// project no longer maps it to that project: nothing is made, and the next pass decides it afresh.
    @Test(arguments: [false, true]) func aQueuedPickUpIsDroppedWhenItsSignalOrProjectNoLongerMakesIt(unmapped: Bool) async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        let entered = TestLatch(), release = TestLatch()
        rig.hold = (entered, release)

        rig.pass(signal, [world.ticket("PAY-1"), world.ticket("PAY-2")])
        await entered.wait()
        rig.workspace.mutate { state in
            if unmapped { state.updateProject(id: world.project.id) { $0.jiraProjects = [] } }
            else { state.signals[0].start = SignalTrigger(source: .gitLab, query: "reviewer:@me") }
        }
        rig.hold = nil; release.signal()
        await rig.settled()

        #expect(rig.requests.count == 1, "PAY-2 is no longer this signal's item for this project.")
        #expect(rig.state.tasks.count == 1 && rig.state.signalSeen.allSatisfy { $0.item.identity != world.ticket("PAY-2").item.identity })
    }

    /// A second project linked to the same Jira project while a ticket waits: the first decision would have skipped the
    /// ticket rather than guess, so the queued pick-up is dropped and nothing is made in either project.
    @Test func aQueuedPickUpIsDroppedWhenASecondProjectNowMapsItsItem() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        let entered = TestLatch(), release = TestLatch()
        rig.hold = (entered, release)

        rig.pass(signal, [world.ticket("PAY-1"), world.ticket("PAY-2")])
        await entered.wait()
        rig.workspace.mutate { state in
            var twin = world.project
            twin.id = UUID(); twin.name = "shop-twin"; twin.path = world.project.path + "-twin"
            state.append(project: twin)
        }
        rig.hold = nil; release.signal()
        await rig.settled()

        #expect(rig.requests.count == 1, "PAY-2 now maps to two projects, so it is not made in either.")
        #expect(rig.state.tasks.count == 1 && rig.state.signalSeen.allSatisfy { $0.item.identity != world.ticket("PAY-2").item.identity })
    }

    /// The window waits for the person's pause; a later quiet releases it, and nothing opens before.
    @Test func thePauseGateHoldsTheWindowAndALaterQuietReleasesIt() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        await rig.start()

        rig.pass(signal, [world.ticket()])
        #expect(await eventually { rig.state.tasks.count == 1 })
        await rig.settled(leaving: 1)
        #expect(rig.opens.isEmpty && rig.state.tasks.first?.signalOrigin?.owed?.kind == .launch)

        typing.idle = 10
        await rig.settled()
        #expect(rig.opens.count == 1 && rig.state.tasks.first?.signalOrigin?.owed == nil)
    }

    /// Choosing the row while it waits for the pause opens it at once.
    @Test func choosingTheRowDuringThePauseWaitOpensItAtOnce() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        await rig.start()
        rig.pass(signal, [world.ticket()])
        #expect(await eventually { rig.state.tasks.count == 1 })
        await rig.settled(leaving: 1)
        let id = try #require(rig.state.tasks.first?.id)

        let launching = try #require(rig.root.projectSignals.choose(id))
        #expect(rig.root.projectSignals.choose(id) == launching, "A second choose joins the launch.")
        await launching.value
        #expect(rig.opens.map(\.id) == [id], "Opened by the time the chooser's wait ends, for it to raise.")
        await rig.settled()
        #expect(rig.opens.map(\.id) == [id])
        #expect(rig.root.projectSignals.choose(id) == nil, "Launched: the row opens as any other.")
    }

    /// Typing that resumes while the open prepares (the folder, the command) holds the window: the pause is looked at
    /// again after those awaits, and the window opens at the next pause.
    @Test func typingResumedDuringTheOpensPreparationHoldsTheWindow() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        await rig.start()
        rig.pass(signal, [world.ticket()])
        #expect(await eventually { rig.state.tasks.count == 1 })
        await rig.settled(leaving: 1)
        var interrupted = 0
        rig.duringOpen = { if interrupted == 0 { typing.idle = 0 }; interrupted += 1 }

        typing.idle = 10
        #expect(await eventually { interrupted == 1 })
        await rig.settled(leaving: 1)
        #expect(rig.opens.isEmpty && rig.state.tasks.first?.signalOrigin?.owed?.kind == .launch, "Typing resumed: held.")

        typing.idle = 10
        await rig.settled()
        #expect(rig.opens.count == 1 && interrupted == 2 && rig.state.tasks.first?.signalOrigin?.owed == nil)
    }

    /// Working published while the open awaits its reply, the prompt still owed then, is the turn's evidence: the turn
    /// ending after the reply notifies.
    @Test func workingSeenWhileTheOpenAwaitsItsReplyCountsForTheTurn() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.duringOpen = { [unowned rig] in
            guard let id = rig.state.tasks.first?.id else { return }
            rig.live.sessions = [OperatorServiceFixtures.session("s1", window: "task-window", tag: id, state: .working)]
        }
        rig.pass(signal, [world.ticket()]); await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        #expect(rig.opens.count == 1 && Self.origin(rig, id)?.turn?.seenWorking == true)

        rig.live.sessions = [OperatorServiceFixtures.session("s1", window: "task-window", tag: id, state: .done)]
        #expect(Self.said(Self.notes(rig).posted) == [Self.ready] && Self.notes(rig).posted.first?.target == .task(id))
    }

    /// With the Operator paused, a project signal still reads and picks up; the Operator signal's read waits.
    @Test func aPausedOperatorStillLetsAProjectPickUpThrough() async throws {
        var world = SignalWorld()
        let operatorSignal = world.signal(), signal = world.projectSignal()
        world.state.operatorSession = OperatorSession(createdAt: world.now); world.state.operatorSession?.paused = true
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let operatorReader = ItemsReader([world.ticket("PAY-1")]), projectReader = ItemsReader([world.ticket("PAY-2")])
        rig.root.sourceRegistrations = { signals in signals.map {
            SignalPoller.Registration(id: $0.id, sourceHost: "jira.example", readKey: $0.isProject ? "review" : "operator", isJira: true,
                                      reader: $0.isProject ? projectReader : operatorReader)
        } }
        await rig.start()

        #expect(await projectReader.reads == 1 && rig.state.tasks.count == 1)
        #expect(await operatorReader.reads == 0, "The Operator's signal waits for Resume.")
        #expect(rig.state.signalSeen.allSatisfy { $0.signal == signal } && !rig.state.signalSeen.contains { $0.signal == operatorSignal })
    }

    /// A read key an Operator and a project signal share reaches the project signal only while the Operator is paused.
    @Test func aSharedReadKeyDeliversTheObservationToTheProjectSignalOnly() async throws {
        var world = SignalWorld()
        let operatorSignal = world.signal(), signal = world.projectSignal()
        world.state.operatorSession = OperatorSession(createdAt: world.now); world.state.operatorSession?.paused = true
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let reader = ItemsReader([world.ticket("PAY-1"), world.ticket("PAY-2")])
        rig.root.sourceRegistrations = { signals in signals.map {
            SignalPoller.Registration(id: $0.id, sourceHost: "jira.example", readKey: "shared", isJira: true, reader: reader)
        } }
        await rig.start()

        #expect(await reader.reads == 1)
        #expect(rig.state.tasks.count == 2 && rig.state.allSignalTasks.isEmpty)
        #expect(Set(rig.state.signalSeen.map(\.signal)) == [signal])
        #expect(!rig.state.signalSeen.contains { $0.signal == operatorSignal })
    }

    /// A queued or creating pick-up claims its item: an Operator signal's match on it meanwhile starts nothing, and once
    /// the task exists, the Operator never continues it.
    @Test func theClaimKeepsAnOperatorSignalOffAQueuedItem() async throws {
        var world = SignalWorld()
        let operatorSignal = world.signal(), signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        let entered = TestLatch(), release = TestLatch()
        rig.hold = (entered, release)

        rig.pass(signal, [world.ticket()])
        await entered.wait()
        rig.pass(operatorSignal, [world.ticket()])
        #expect(rig.state.allSignalTasks.isEmpty && !rig.state.signalSeen.contains { $0.signal == operatorSignal })
        rig.hold = nil; release.signal()
        await rig.settled()
        rig.pass(operatorSignal, [world.ticket()]); await rig.settled()
        #expect(rig.state.tasks.count == 1 && rig.state.allSignalTasks.isEmpty)
    }

    /// While the helper is away nothing is made; the first tick once it is back makes the pick-up queued meanwhile.
    @Test func theRunnerWaitsWhileTheHelperIsAway() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.helper = false
        await rig.start()

        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.requests.isEmpty)
        rig.helper = true
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.requests.count == 1 && rig.opens.count == 1)
    }

    /// A task saved owing its launch, with no agent and no conversation (AiTerm quit while it waited for the pause),
    /// opens once at the next start, and never twice.
    @Test func aRelaunchWithAnOwedLaunchOpensOnceAndNeverTwice() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .launch, window: nil)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()

        #expect(rig.opens.map(\.id) == [id] && rig.opens.first?.prompt == "Owed prompt")
        await rig.root.reconcile(); await rig.settled()
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.opens.count == 1)
        #expect(rig.state.task(id: id)?.signalOrigin?.owed == nil && rig.state.task(id: id)?.signalOrigin?.turn?.sentAt == world.now)
    }

    /// A launch whose answer was lost: a task owing its launch with a live agent of its own is taken as launched, with no
    /// second prompt. A delivery owed to a task with a conversation is never cleared by recovery: it waits while its worker
    /// works and is typed into that conversation once the worker is idle.
    @Test func aRestartWithALaunchDebtAndALiveAgentClearsItAndKeepsADeliveryDebt() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let launched = world.owing(signal: signal, .launch, window: "w1")
        let delivering = world.owing(signal: signal, .delivery, window: "w2", conversations: [TaskConversation(agent: .claude, id: "earlier")])
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "w1", tag: launched, state: .working, conversation: "first"),
                             OperatorServiceFixtures.session("worker", window: "w2", tag: delivering, state: .working, conversation: "earlier")]
        await rig.start()

        #expect(rig.opens.isEmpty && rig.deliveries.isEmpty, "No second prompt, and nothing typed while the worker works.")
        #expect(rig.state.task(id: launched)?.signalOrigin?.owed == nil)
        #expect(rig.state.task(id: launched)?.signalOrigin?.turn?.sentAt == world.now)
        #expect(rig.state.task(id: delivering)?.signalOrigin?.owed?.kind == .delivery)
        let saved = try rig.workspace.file.load()
        #expect(saved.task(id: launched)?.signalOrigin?.owed == nil && saved.task(id: delivering)?.signalOrigin?.owed != nil)

        rig.live.sessions[1].state = .idle
        await rig.settled()
        #expect(rig.deliveries.map(\.session) == ["worker"] && rig.deliveries.first?.text == "Owed prompt")
        #expect(rig.opens.isEmpty)
        #expect(try rig.workspace.file.load().task(id: delivering)?.signalOrigin?.owed == nil)
    }

    /// Through the app's own wiring and a real checkout: the row, its origin and the item's started record are never in
    /// the workspace one without the other and are saved together; the window opens behind with the ordinary command,
    /// no worker guard and no denied tools, the descriptions once; nothing is chosen or brought forward.
    @Test(.blocking) func theAppsLauncherMakesAnOrdinaryTaskAndOpensItBehind() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, signals = controller.signalController
        controller.helper.setDaemonClient(server)
        let world = SignalWorld()
        let jira = JiraProjectRef(id: "1", key: "PAY", name: "Payments", siteURL: URL(string: "https://jira.example")!)
        let signal = Signal.project(name: "Plan for me", start: SignalTrigger(source: .jira, query: "labels = review"))
        controller.workspace.mutate { state in
            state.updateProject(id: fixture.project.id) { $0.jiraProjects = [jira] }
            state.signals = [signal]
        }
        #expect(controller.workspace.flush())
        var torn: [UUID] = []
        controller.workspace.onChange {
            let started = Set(controller.state.signalSeen.filter { $0.disposition == .started }.compactMap(\.item.identity))
            torn += controller.state.tasks.filter { $0.signalOrigin.map { !started.contains($0.item.identity ?? "") } ?? true }.map(\.id)
        }
        signals.sourceRegistrations = { _ in [] }; signals.tabsKnown = true
        signals.start(); await signals.ports.work.settled()

        signals.poller.onPass([SignalObservation(signals: [signal.id], read: SignalRead(items: [world.ticket()], complete: true))])
        await signals.ports.work.settled()

        #expect(torn.isEmpty, "The row is never in the workspace without its origin and its started record.")
        let saved = try controller.workspace.file.load()
        let task = try #require(saved.tasks.first)
        #expect(task.signalOrigin?.signal == signal.id && task.signalOrigin?.owed == nil && task.signalTask == nil)
        #expect(task.jira?.key == "PAY-1" && task.kind == .task && task.baseBranch == "main")
        #expect(saved.signalSeen.map(\.disposition) == [.started])
        let window = try #require(server.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true)
        let command = try #require(window.params["agentCommand"] as? String)
        #expect(command.hasPrefix("claude ") && !command.contains("--disallowedTools"))
        #expect(command.components(separatedBy: "untrusted item descriptions").count == 2)
        #expect(server.requests("window.activate").isEmpty && controller.focus.selectedTaskId == nil)
        #expect(server.requests("operator.register").isEmpty && !controller.state.operatorHasWork)
    }

    // -- re-match delivery ---------------------------------------------------------------

    /// A worker idle in the task's window, its conversation the one the task remembers.
    static func idle(_ id: UUID, window: String = "w1", _ state: SessionState = .idle) -> SessionInfo {
        OperatorServiceFixtures.session("s1", window: window, tag: id, state: state, conversation: "c1")
    }
    static func origin(_ rig: PickupRig, _ id: UUID) -> SignalOrigin? { rig.state.signalItem(id: id)?.signalOrigin }

    /// The helper refuses while the person types, then while their words wait unsent: the prompt stays owed, a change to
    /// the tabs does not ask again, and the next tick does, until a tick types it.
    @Test func aTypingOrUnsentRefusalKeepsThePromptOwedAndALaterTickTypesIt() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(id)]
        rig.deliveryResults = [Delivery(result: .refused, reason: "you are typing", code: .typing),
                               Delivery(result: .refused, reason: "unsent text waits in its input", code: .unsentInput)]
        await rig.start()

        #expect(rig.deliveries.map(\.text) == ["Owed prompt"] && rig.deliveries.first?.worktree == rig.state.task(id: id)?.worktreePath)
        #expect(Self.origin(rig, id)?.owed?.kind == .delivery && rig.state.signalSeen.isEmpty, "A busy person is no reason to show.")
        rig.live.sessions = [Self.idle(id)]
        await rig.settled()
        #expect(rig.deliveries.count == 1, "A refusal waits for the next tick.")
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.count == 2 && Self.origin(rig, id)?.owed != nil)
        rig.clock.advance(by: 60)
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.count == 3 && Self.origin(rig, id)?.owed == nil)
        #expect(Self.origin(rig, id)?.turn == SignalTurn(sentAt: rig.clock.now) && Self.origin(rig, id)?.notifiedAt == nil)
        #expect(rig.opens.isEmpty)
    }

    /// The item leaves the read and matches again: the task's origin owes the prompt as a delivery, Done and Then cleared,
    /// and it is typed once into the same session; no second task, no window.
    @Test func aRecordFlippedToNotMatchingAndANewMatchYieldsOneDeliveryToTheSameSession() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.pass(signal, [world.ticket()]); await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        rig.workspace.mutate { $0.updateSignalItem(id) { $0.signalOrigin?.doneAt = world.now; $0.signalOrigin?.thenApplied = true; $0.signalOrigin?.notifiedAt = world.now } }
        rig.live.sessions = [Self.idle(id, window: "opened-1")]
        await rig.settled()
        #expect(rig.deliveries.isEmpty, "Nothing is owed.")

        rig.clock.advance(by: 120)
        rig.pass(signal, [])
        rig.pass(signal, [world.ticket()])
        rig.pass(signal, [world.ticket()])
        await rig.settled()

        #expect(rig.deliveries.map(\.session) == ["s1"])
        let first = try #require(rig.opens.first?.prompt), again = try #require(rig.deliveries.first?.text)
        #expect(again.components(separatedBy: "\n").first == first.components(separatedBy: "\n").first)
        #expect(again.components(separatedBy: "Use an idempotency key.").count == first.components(separatedBy: "Use an idempotency key.").count)
        let origin = try #require(Self.origin(rig, id))
        #expect(origin.owed == nil && origin.turn == SignalTurn(sentAt: rig.clock.now) && origin.notifiedAt == nil)
        #expect(origin.doneAt == nil && origin.thenApplied == nil && origin.signal == signal && origin.earlier == nil)
        #expect(rig.state.tasks.count == 1 && rig.requests.count == 1 && rig.opens.count == 1)
        #expect(rig.state.signalSeen.map(\.disposition) == [.started] && rig.state.signalSeen.first?.isMatching == true)
    }

    /// Nothing is typed while the worker works or asks; it is typed the moment its turn ends.
    @Test func nothingIsTypedWhileTheSessionWorksAndItIsTypedWhenItTurnsIdle() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(id, .working)]
        await rig.start()
        #expect(rig.deliveries.isEmpty && rig.opens.isEmpty)
        rig.live.sessions = [Self.idle(id, .needsInput)]
        await rig.settled()
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.isEmpty && Self.origin(rig, id)?.owed != nil)

        rig.live.sessions = [Self.idle(id, .done)]
        await rig.settled()
        #expect(rig.deliveries.map(\.session) == ["s1"] && Self.origin(rig, id)?.owed == nil)
    }

    /// A second re-match before the first was delivered leaves one prompt owed, the newer, and one is typed.
    @Test func aSecondRematchBeforeDeliveryLeavesOnePromptTheNewer() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.pass(signal, [world.ticket()]); await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        rig.live.sessions = [Self.idle(id, window: "opened-1", .working)]

        for _ in 0..<2 {
            rig.clock.advance(by: 60)
            rig.pass(signal, []); rig.pass(signal, [world.ticket()]); await rig.settled()
        }
        #expect(Self.origin(rig, id)?.owed?.at == rig.clock.now && Self.origin(rig, id)?.owed?.kind == .delivery)
        rig.live.sessions = [Self.idle(id, window: "opened-1")]
        await rig.settled()
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.count == 1 && Self.origin(rig, id)?.owed == nil)
    }

    /// A pasted prompt whose Enter is the person's clears the debt: the turn is pasted, not sent.
    @Test func aPartialDeliveryClearsTheDebtAndSetsPastedAt() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(id)]
        rig.deliveryResults = [Delivery(result: .partial, reason: "pasted without Enter", code: .pasteOnly)]
        await rig.start()

        let origin = try #require(Self.origin(rig, id))
        #expect(origin.owed == nil && origin.turn == SignalTurn(pastedAt: world.now) && origin.turn?.sentAt == nil)
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.count == 1)
    }

    /// An agent whose messaging check has not passed: refused by the helper, the prompt stays owed, and why is the signal's
    /// skipped record beside its started one; it is asked again at the next tick, and the reason goes once it is typed.
    @Test func aRefusalForAnUncheckedAgentStaysOwedAndSaysWhy() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(id)]
        rig.deliveryResults = [Delivery(result: .refused, reason: "claude 2.2.0 has not passed the delivery check", code: .notChecked)]
        await rig.start()

        #expect(Self.origin(rig, id)?.owed != nil)
        #expect(rig.state.signalSeen.map(\.reason) == ["Its prompt couldn’t be typed: claude 2.2.0 has not passed the delivery check"])
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.count == 2 && Self.origin(rig, id)?.owed == nil && rig.state.signalSeen.isEmpty)
    }

    /// A task whose window was closed is opened behind with the prompt, in the pause, as the launch is.
    @Test func aTaskWithNoWindowIsOpenedBehindWithThePrompt() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: nil, conversations: [TaskConversation(agent: .claude, id: "c1")])
        world.state.signals[0].enabled = false
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        await rig.start()
        rig.workspace.mutate { $0.signals[0].enabled = true }
        await rig.root.reconcile()
        await rig.settled(leaving: 1)
        #expect(rig.opens.isEmpty && Self.origin(rig, id)?.owed != nil, "The window waits for the person's pause.")

        typing.idle = 10
        await rig.settled()
        #expect(rig.opens.map(\.id) == [id] && rig.opens.first?.prompt == "Owed prompt" && rig.deliveries.isEmpty)
        #expect(Self.origin(rig, id)?.owed == nil && Self.origin(rig, id)?.turn?.sentAt == world.now)
    }

    /// A signal switched off while its re-match's window waits for the pause, or as the window is asked for, opens
    /// nothing and keeps the prompt owed; switched on again, the window opens with it.
    @Test(arguments: [false, true]) func switchingOffWhileTheDeliveryWaitsKeepsThePromptOwedUntilItIsOn(asItOpens: Bool) async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: nil, conversations: [TaskConversation(agent: .claude, id: "c1")])
        world.state.signals[0].enabled = false
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        await rig.start()
        var interrupted = 0
        rig.duringOpen = { [unowned rig] in
            if asItOpens && interrupted == 0 { rig.workspace.mutate { $0.signals[0].enabled = false } }
            interrupted += 1
        }
        rig.workspace.mutate { $0.signals[0].enabled = true }
        await rig.root.reconcile()
        await rig.settled(leaving: 1)
        #expect(rig.opens.isEmpty && Self.origin(rig, id)?.owed != nil, "The window waits for the person's pause.")

        if !asItOpens { rig.workspace.mutate { $0.signals[0].enabled = false } }
        typing.idle = 10
        await rig.settled()
        #expect(rig.opens.isEmpty && Self.origin(rig, id)?.owed?.kind == .delivery, "Switched off: nothing opens, still owed.")

        rig.workspace.mutate { $0.signals[0].enabled = true }
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.opens.map(\.id) == [id] && rig.opens.first?.prompt == "Owed prompt" && Self.origin(rig, id)?.owed == nil)
    }

    /// A signal switched off as a first launch's window is asked for opens nothing and keeps the launch owed; switched
    /// on again, the window opens.
    @Test func switchingOffAsTheLaunchOpensKeepsItOwedUntilItIsOn() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        var interrupted = 0
        rig.duringOpen = { [unowned rig] in
            if interrupted == 0 { rig.workspace.mutate { $0.signals[0].enabled = false } }
            interrupted += 1
        }
        rig.pass(signal, [world.ticket()])
        await rig.settled()
        #expect(interrupted == 1 && rig.opens.isEmpty && rig.state.tasks.first?.signalOrigin?.owed?.kind == .launch)

        rig.workspace.mutate { $0.signals[0].enabled = true }
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.opens.count == 1 && rig.state.tasks.first?.signalOrigin?.owed == nil)
    }

    /// An archived task is restored first, then opened as a closed window is.
    @Test func anArchivedTaskIsRestoredFirst() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: nil, conversations: [TaskConversation(agent: .claude, id: "c1")])
        let task = try #require(world.state.task(id: id))
        world.state.tasks.removeAll { $0.id == id }
        world.state.archive.append(ArchivedTask(task: task, archivedAt: world.now))
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()

        #expect(rig.effects == ["restore", "open"] && rig.restores == [id] && rig.opens.map(\.id) == [id])
        #expect(rig.state.task(id: id) != nil && Self.origin(rig, id)?.owed == nil)
    }

    /// A restore git refuses keeps the prompt owed, its reason the signal's skipped record, and is tried again after the
    /// back-off.
    @Test func aRestoreRefusedByGitKeepsThePromptOwedWithItsReason() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: nil)
        let task = try #require(world.state.task(id: id))
        world.state.tasks.removeAll { $0.id == id }
        world.state.archive.append(ArchivedTask(task: task, archivedAt: world.now))
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.restoreFailures = [ActionUnavailable("fatal: a branch named feat/work already exists")]
        await rig.start()

        #expect(rig.state.archived(id: id) != nil && Self.origin(rig, id)?.owed?.kind == .delivery && rig.opens.isEmpty)
        #expect(rig.state.signalSeen.map(\.reason) == ["Couldn’t restore its task: fatal: a branch named feat/work already exists"])
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.restores.count == 1, "Backing off.")
        rig.clock.advance(by: SignalPoller.failureBackOff)
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.restores.count == 2 && rig.opens.map(\.id) == [id] && rig.state.signalSeen.isEmpty)
    }

    /// An owed prompt whose signal was removed is cleared; one whose signal is switched off waits for it.
    @Test func aRemovedSignalsPromptIsClearedAndASwitchedOffOneWaits() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(), removed = world.projectSignal(name: "Gone")
        let waiting = world.owing(signal: signal, .delivery, window: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        let orphan = world.owing(signal: removed, .delivery, window: "w2")
        world.state.signals.removeAll { $0.id == removed }
        world.state.signals[0].enabled = false
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(waiting)]
        await rig.start()

        #expect(Self.origin(rig, orphan)?.owed == nil && Self.origin(rig, orphan)?.turn == nil)
        #expect(Self.origin(rig, waiting)?.owed != nil && rig.deliveries.isEmpty && rig.opens.isEmpty)
        rig.workspace.mutate { $0.signals[0].enabled = true }
        await rig.root.reconcile(); await rig.settled()
        #expect(rig.deliveries.count == 1 && Self.origin(rig, waiting)?.owed == nil)
    }

    /// O1: a task you made for the item is marked with the signal on its first match and gets the prompt in its own
    /// conversation; the Operator never holds it.
    @Test func aHandMadeTaskGainsAnOriginAndGetsThePrompt() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let ticket = try #require(world.ticket().ticket)
        let mine = TaskItem.make(project: world.project.id, worktreePath: world.project.path + "/.worktrees/mine", jira: JiraRef(ticket),
                                 windowId: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        world.state.tasks.append(mine)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(mine.id)]
        await rig.start()

        rig.pass(signal, [world.ticket()]); await rig.settled()
        let task = try #require(rig.state.task(id: mine.id))
        #expect(task.signalTask == nil && rig.state.tasks.count == 1 && rig.requests.isEmpty)
        #expect(task.signalOrigin?.signal == signal && task.signalOrigin?.item == world.ticket().item)
        #expect(task.signalOrigin?.owed == nil && task.signalOrigin?.turn?.sentAt == world.now)
        #expect(rig.deliveries.map(\.session) == ["s1"] && rig.opens.isEmpty)
        #expect(rig.state.signalSeen.map(\.disposition) == [.started])
    }

    /// Through the app's own wiring: a task owing a delivery whose window is closed is opened behind, resuming its first
    /// conversation with the prompt, and its debt is saved cleared with the window.
    @Test(.blocking) func theAppOpensAClosedWindowBehindWithAResumeCommand() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, signals = controller.signalController
        controller.helper.setDaemonClient(server)
        let signal = Signal.project(name: "Review again", start: SignalTrigger(source: .jira, query: "labels = review"))
        let task = try await fixture.addTask(windowId: nil)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        controller.workspace.mutate { state in
            state.signals = [signal]
            state.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1")]
            state.tasks[0].signalOrigin = SignalOrigin(signal: signal.id, name: signal.name, item: SignalWorld().ticket().item, startedAt: at,
                                                       owed: OwedPrompt(text: "Again", at: at, kind: .delivery))
        }
        #expect(controller.workspace.flush())
        signals.sourceRegistrations = { _ in [] }; signals.tabsKnown = true
        signals.start(); await signals.ports.work.settled()

        let window = try #require(server.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true)
        let command = try #require(window.params["agentCommand"] as? String)
        #expect(command.hasPrefix("codex resume thread-1 ") && command.hasSuffix("'Again'"))
        #expect(server.requests("session.deliver").isEmpty && server.requests("window.activate").isEmpty)
        let saved = try #require(try controller.savedWorkspace().task(id: task.id))
        #expect(saved.windowId != nil && saved.signalOrigin?.owed == nil && saved.signalOrigin?.turn?.sentAt != nil)
    }

    // -- the turn's notification --------------------------------------------------------

    static func notes(_ rig: PickupRig) -> RecordingNotifications { rig.ports.notifications as! RecordingNotifications }
    /// The task's own worker in `state`, in its window `task-window` (`SignalWorld.markedTask`).
    static func worker(_ id: UUID, _ state: SessionState, session: String = "s1") -> SessionInfo {
        OperatorServiceFixtures.session(session, window: "task-window", tag: id, state: state, conversation: "c1")
    }
    static let ready = " is ready for you, in shop."
    static let asks = " asks you something, in shop."
    /// What each note says, by its ending: the body starts with the item and the task's title.
    static func said(_ notes: [OperatorNote]) -> [String] {
        notes.map { note in [ready, asks].first { note.body.hasSuffix($0) } ?? note.body }
    }

    /// O1: a task you made, its worker already done, is marked and gets the prompt; nothing is posted for the done it
    /// already was, and one note once the turn the prompt started worked and ended.
    @Test func aHandMadeTaskAlreadyDoneIsNotifiedOnlyAfterTheSignalsTurnWorkedAndEnded() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let ticket = try #require(world.ticket().ticket)
        let mine = TaskItem.make(project: world.project.id, title: "Retries", worktreePath: world.project.path + "/.worktrees/mine",
                                 jira: JiraRef(ticket), windowId: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        world.state.tasks.append(mine)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(mine.id, .done)]
        await rig.start()

        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.deliveries.count == 1 && Self.origin(rig, mine.id)?.turn?.sentAt == world.now)
        rig.live.sessions = [Self.idle(mine.id, .done)]
        await rig.root.reconcile(); await rig.settled()
        #expect(Self.notes(rig).posted.isEmpty, "Done before the prompt is no evidence of its turn.")

        rig.live.sessions = [Self.idle(mine.id, .working)]
        #expect(Self.notes(rig).posted.isEmpty && Self.origin(rig, mine.id)?.turn?.seenWorking == true)
        rig.clock.advance(by: 90)
        rig.live.sessions = [Self.idle(mine.id, .done)]
        #expect(Self.notes(rig).posted == [OperatorNote(id: SignalTurnNotification.id(mine.id), title: "Review tickets",
                                                         body: "\(ticket.key) Retries" + Self.ready,
                                                         target: .task(mine.id))])
        #expect(try rig.workspace.file.load().task(id: mine.id)?.signalOrigin?.notifiedAt == rig.clock.now)
    }

    /// A pasted prompt is the person's to send: nothing while it waits in the input, one note once they sent it and the
    /// turn worked and ended.
    @Test func aPastedPromptNotifiesOnlyAfterThePersonSentItAndItWorked() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.owing(signal: signal, .delivery, window: "w1", conversations: [TaskConversation(agent: .claude, id: "c1")])
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.idle(id)]
        rig.deliveryResults = [Delivery(result: .partial, reason: "pasted without Enter", code: .pasteOnly)]
        await rig.start()
        #expect(Self.origin(rig, id)?.turn == SignalTurn(pastedAt: world.now))

        var touched = Self.idle(id); touched.contextPercent = 40
        for session in [Self.idle(id), touched, Self.idle(id, .done)] {
            rig.live.sessions = [session]
            await rig.root.reconcile(); await rig.settled()
        }
        #expect(Self.notes(rig).posted.isEmpty && Self.origin(rig, id)?.turn?.seenWorking == nil, "Never sent, never notified.")

        rig.live.sessions = [Self.idle(id, .working)]
        rig.live.sessions = [Self.idle(id)]
        #expect(Self.said(Self.notes(rig).posted) == [Self.ready])
    }

    /// Changes to the tabs that are not the turn working say nothing: a context fill, a shell of the task at work, another
    /// task's worker at work and done.
    @Test func unrelatedSessionUpdatesDoNotNotify() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.sent(signal: signal)
        let other = world.state.tasks.count
        world.state.tasks.append(TaskItem.make(project: world.project.id, worktreePath: world.project.path + "/.worktrees/other"))
        let neighbour = world.state.tasks[other].id
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [Self.worker(id, .idle)]
        await rig.start()

        var touched = Self.worker(id, .idle); touched.contextPercent = 55
        let shell = OperatorServiceFixtures.session("s2", window: "task-window", tag: id, agent: .shell, state: .working)
        for sessions in [[touched], [touched, shell], [touched, Self.worker(neighbour, .working, session: "s3")],
                         [touched, Self.worker(neighbour, .done, session: "s3")], [Self.worker(id, .done)]] {
            rig.live.sessions = sessions
        }
        await rig.root.reconcile(); await rig.settled()
        #expect(Self.notes(rig).posted.isEmpty && Self.origin(rig, id)?.turn?.seenWorking == nil)
    }

    /// Posted once across repeated session events and across a restart; a restart after the turn ended (its working seen
    /// and saved) posts it once; the task going takes it back.
    @Test func theNoteIsPostedOnceAcrossRepeatedEventsAndARestart() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.sent(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        for state in [SessionState.working, .done, .done, .idle, .working, .done] { rig.live.sessions = [Self.worker(id, state)] }
        await rig.root.reconcile(); await rig.settled()
        #expect(Self.notes(rig).posted.count == 1)

        var after = world; after.state = try rig.workspace.file.load()
        let restarted = try PickupRig(after); defer { restarted.cleanUp() }
        restarted.live.sessions = [Self.worker(id, .done)]
        await restarted.start()
        #expect(Self.notes(restarted).posted.isEmpty, "Its notifiedAt was saved before the post.")

        var ended = SignalWorld(); let again = ended.projectSignal()
        let seen = ended.sent(signal: again, seenWorking: true)
        let reopened = try PickupRig(ended); defer { reopened.cleanUp() }
        reopened.live.sessions = [Self.worker(seen, .done)]
        await reopened.start()
        reopened.live.sessions = [Self.worker(seen, .done)]
        #expect(Self.notes(reopened).posted.map(\.id) == [SignalTurnNotification.id(seen)])

        reopened.workspace.mutate { $0.tasks.removeAll { $0.id == seen } }
        #expect(Self.notes(reopened).withdrawn == [SignalTurnNotification.id(seen)])
    }

    /// The worker asking says "asks you something", and nothing more for that turn; background work running at the
    /// turn's end holds it until the real end, which says "is ready for you".
    @Test func theWordingFollowsTheWorkersState() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let asking = world.sent(signal: signal), busy = world.sent(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        var holding = Self.worker(busy, .done, session: "s2")
        holding.work = [WorkItem(kind: .shell, text: "npm run build", holdsTurn: true)]

        rig.live.sessions = [Self.worker(asking, .working), Self.worker(busy, .working, session: "s2")]
        rig.live.sessions = [Self.worker(asking, .needsInput), holding]
        #expect(Self.said(Self.notes(rig).posted) == [Self.asks] && Self.notes(rig).posted.first?.target == .task(asking))
        rig.live.sessions = [Self.worker(asking, .done), holding]
        await rig.root.reconcile(); await rig.settled()
        #expect(Self.notes(rig).posted.count == 1, "Asking was the turn's note; the background work still holds the other.")

        rig.live.sessions = [Self.worker(asking, .done), Self.worker(busy, .done, session: "s2")]
        #expect(Self.said(Self.notes(rig).posted) == [Self.asks, Self.ready] && Self.notes(rig).posted.last?.target == .task(busy))
    }

    /// No note for an Operator task, a task taken over from the Operator or a task you made, whatever their turns.
    @Test func nothingIsPostedForAnOperatorTaskATakenOverTaskOrATaskYouMade() async throws {
        var world = SignalWorld(); let operatorSignal = world.signal(), signal = world.projectSignal()
        let operated = world.workingTask(signal: operatorSignal), taken = world.workingTask(signal: operatorSignal)
        _ = world.state.takeOver(taken)
        let item = world.ticket().item, now = world.now
        for id in [operated, taken] {
            world.state.updateSignalItem(id) { task in
                if task.signalOrigin == nil { task.signalOrigin = SignalOrigin(signal: signal, name: "Review tickets", item: item, startedAt: now) }
                task.signalOrigin?.turn = SignalTurn(sentAt: now)
            }
        }
        let yours = TaskItem.make(project: world.project.id, worktreePath: world.project.path + "/.worktrees/yours")
        world.state.tasks.append(yours)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        let ids = [operated, taken, yours.id]
        for state in [SessionState.working, .needsInput, .done] {
            rig.live.sessions = ids.enumerated().map { Self.worker($1, state, session: "s\($0)") }
        }
        await rig.root.reconcile(); await rig.settled()
        #expect(Self.notes(rig).posted.isEmpty)
    }

    /// Through the app's wiring: the note's click chooses the task's row, as a click on the row does, and choosing the
    /// row takes the note back.
    @Test func aTurnNoteChoosesItsTaskAndChoosingTheRowTakesItBack() throws {
        let controller = AppController(preferences: .scratch()); try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.sent(signal: signal, notified: world.now)
        controller.workspace.mutate { $0 = world.state }
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try #require(controller.state.task(id: id))
        let note = try #require(SignalTurnNotification.make(task: task, reason: .ready, state: controller.state))
        #expect(note.target == .task(id) && note.body.hasSuffix(Self.ready) && note.title == "Review tickets")

        controller.signalController.ports.notifications.onOpen?(note.target)
        #expect(controller.focus.selection == .task(id))
        let notes = try #require(controller.signalController.ports.notifications as? RecordingNotifications)
        #expect(notes.withdrawn == [SignalTurnNotification.id(id)])
    }

    nonisolated static func request(_ iid: Int, source: String = "feat/work", fork: String? = nil, description: String? = nil) -> SignalItem {
        let request = MergeRequest(iid: iid, title: "Work", sourceBranch: source, targetBranch: "main", author: "sam", state: "opened",
                                   draft: false, url: "https://git.example/shop/web/-/merge_requests/\(iid)", forkHead: fork,
                                   description: description)
        return SignalItem(item: .request(remote: "https://git.example/shop/web", number: iid), title: "Work", mergeRequest: request)
    }

    static func activity(_ rig: PickupRig) -> [ActivityEntry] {
        ActivityLogReader.read(folder: OperatorLaunch.folder(home: rig.ports.home)).entries
    }
}

/// The controller on a harness, its pick-ups' create and open scripted: a create appends the draft's row and runs the
/// request's `saving` in one change, then saves, as `TaskLauncher.createUnattended` does; an open records the prompt
/// and runs its `saving`, as `openUnattended` does with the window. A restore moves the row out of the archive (or throws
/// the next of `restoreFailures`); a delivery is recorded and answers the next of `deliveryResults`, else delivered.
@MainActor final class PickupRig {
    let world: SignalWorld, h: SignalHarness, live: LiveSessions, daemon: RecordingDaemon, clock: TestClock
    let ports: OperatorPorts, root: SignalOperatorController
    var workspace: WorkspaceStore { h.workspace }
    var state: AppState { h.workspace.state }
    private(set) var requests: [TaskLauncher.UnattendedCreate] = []
    private(set) var opens: [(id: UUID, prompt: String)] = []
    private(set) var restores: [UUID] = []
    private(set) var deliveries: [(session: String, text: String, worktree: String?)] = []
    /// What each port was asked, in order: "restore", "open", "deliver".
    private(set) var effects: [String] = []
    var restoreFailures: [any Error] = []
    var deliveryResults: [Delivery] = []
    /// Thrown by the next creates, in order.
    var failures: [any Error] = []
    /// Holds each create until released: `entered` is signalled as it starts.
    var hold: (entered: TestLatch, release: TestLatch)?
    /// Runs as each open is asked for, before its last look at the pause: what changes while the real one awaits.
    var duringOpen: (@MainActor () -> Void)?
    /// Whether the helper is there.
    var helper: Bool { get { presence.there } set { presence.there = newValue } }
    private let presence: Presence
    @MainActor private final class Presence { var there = true }

    init(_ world: SignalWorld, pause: PauseGate = .never) throws {
        self.world = world
        let h = try SignalHarness(world), clock = TestClock(world.now), daemon = RecordingDaemon(), presence = Presence()
        self.h = h; self.clock = clock; self.daemon = daemon; self.presence = presence
        live = LiveSessions(workspace: h.workspace)
        var ports = OperatorPorts.scratch(); ports.clock.now = { clock.now }; ports.pause = pause
        self.ports = ports
        root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { presence.there ? daemon : nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }
        root.tabsKnown = true
        root.projectSignals.ports = .init(create: { [unowned self] request in try await self.create(request) },
                                          open: { [unowned self] id, prompt, mayOpen, saving in
            self.duringOpen?()
            guard mayOpen() else { return false }
            self.opens.append((id, prompt)); self.effects.append("open")
            self.workspace.mutate { state in
                state.updateSignalItem(id) { $0.windowId = "opened-\(self.opens.count)" }
                saving(&state)
            }
            return true
        }, restore: { [unowned self] id in
            self.restores.append(id); self.effects.append("restore")
            if !self.restoreFailures.isEmpty { throw self.restoreFailures.removeFirst() }
            self.workspace.mutate { _ = $0.moveFromArchive(id: id) }
            self.workspace.flush()
        }, deliver: { [unowned self] session, text, worktree in
            self.deliveries.append((session, text, worktree)); self.effects.append("deliver")
            return self.deliveryResults.isEmpty ? Delivery(result: .delivered, reason: nil) : self.deliveryResults.removeFirst()
        })
    }
    func start() async { root.start(); await ports.work.settled() }
    func settled(leaving count: Int = 0) async { await ports.work.settled(leaving: count) }
    func cleanUp() { root.stop(); h.cleanUp(); try? FileManager.default.removeItem(at: ports.home) }
    /// A complete, full read of `items` for `signal`, handed to the controller as the poller does.
    func pass(_ signal: UUID, _ items: [SignalItem], accountUser: String? = nil) {
        root.poller.onPass([SignalObservation(signals: [signal], read: SignalRead(items: items, complete: true, accountUser: accountUser))])
    }

    private func create(_ request: TaskLauncher.UnattendedCreate) async throws -> UUID {
        requests.append(request)
        if let hold { hold.entered.signal(); await hold.release.wait() }
        if !failures.isEmpty { throw failures.removeFirst() }
        let project = request.project.id
        let task: TaskItem = switch request.kind {
        case .task(let draft), .run(let draft):
            .make(project: project, title: draft.title, branch: draft.branch, jira: draft.ticket.map(JiraRef.init), kind: .task,
                  agent: draft.agent, model: draft.model, reasoning: draft.reasoning)
        case .review(let draft):
            .make(project: project, title: draft.title, branch: draft.branch, kind: .review,
                  mr: draft.mr.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) },
                  agent: draft.agent, model: draft.model, reasoning: draft.reasoning)
        case .ownRequest(let draft):
            .make(project: project, title: draft.title, branch: draft.branch, kind: .task,
                  mr: draft.mr.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) },
                  agent: draft.agent, model: draft.model, reasoning: draft.reasoning)
        }
        workspace.mutate { state in
            state.tasks.append(task)
            request.saving(&state, task.id)
        }
        guard workspace.flush() else { throw ActionUnavailable("Not saved.") }
        return task.id
    }
}

/// A person typing until told otherwise: the gate is quiet once `idle` reaches the pause.
@MainActor final class Typing {
    var idle: TimeInterval = 0
    lazy var gate = PauseGate(pause: 5, idle: { [unowned self] in self.idle }, sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
}

/// A source that lists the same items at every read.
actor ItemsReader: SignalSourceReader {
    let items: [SignalItem]
    var reads = 0
    init(_ items: [SignalItem]) { self.items = items }
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        reads += 1
        return SignalRead(items: items, complete: true, full: full)
    }
}

extension SignalWorld {
    /// A task `signal` started on the world's ticket that still owes it a prompt of `kind`.
    @discardableResult mutating func owing(signal: UUID, _ kind: OwedPrompt.Kind, window: String?,
                                           conversations: [TaskConversation] = []) -> UUID {
        var task = TaskItem.make(project: project.id, worktreePath: project.path + "/.worktrees/\(kind)", windowId: window,
                                 conversations: conversations)
        let item = ticket(kind == .launch ? "PAY-7" : "PAY-8").item
        task.signalOrigin = SignalOrigin(signal: signal, name: state.signal(id: signal)?.name ?? "", item: item, startedAt: now,
                                         owed: OwedPrompt(text: "Owed prompt", at: now, kind: kind))
        state.tasks.append(task)
        return task.id
    }

    /// A task `signal` started whose prompt was sent at the world's now, nothing owed: its turn `seenWorking` or not
    /// yet, notified at `notified`.
    @discardableResult mutating func sent(signal: UUID, seenWorking: Bool? = nil, notified: Date? = nil) -> UUID {
        let id = markedTask(signal: signal), now = now
        state.updateSignalItem(id) { task in
            task.signalOrigin?.turn = SignalTurn(sentAt: now, seenWorking: seenWorking)
            task.signalOrigin?.notifiedAt = notified
        }
        return id
    }
}
