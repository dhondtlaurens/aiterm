import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// New Broadcast's Start waits for what a broadcast needs: every agent the Operator may plan on Ready,
/// Messaging included, and iTerm2's own checks passed. What is not ready is one footer line each, in
/// the words that agent's card says it.
@MainActor
@Suite struct BroadcastReadinessTests {
    private let model = AgentModel(id: "m", label: "M", detail: nil, efforts: [], defaultEffort: nil)

    private func card(_ agent: AgentKind, integration: HarnessIntegrationState = .current) -> HarnessSnapshot {
        .reduce(agent: agent, cliAvailable: true, integrationState: integration, models: [model],
                checks: [HarnessCheck(.cli, passed: true, explanation: nil),
                         HarnessCheck(.integration, passed: integration == .current,
                                      explanation: integration == .current ? nil : "Driver is not installed.")])
    }

    private var cards: [AgentKind: HarnessSnapshot] { [.claude: card(.claude), .codex: card(.codex)] }
    private let ready: [AgentKind: DeliveryReadiness] = [.claude: .ready("Messaging ready for 2.1"), .codex: .ready("Messaging ready for 0.160")]
    private let itermPassed = DeliveryReadiness.ready("iTerm2 checks passed")

    private func readiness(installed: Set<AgentKind> = [.claude, .codex], cards: [AgentKind: HarnessSnapshot]? = nil,
                           messaging: [AgentKind: DeliveryReadiness]? = nil, iterm: DeliveryReadiness?? = .none) -> BroadcastReadiness {
        let messaging = messaging ?? ready
        return BroadcastReadiness.of(installed: installed, snapshots: cards ?? self.cards, messaging: { messaging[$0] },
                                     iterm: iterm ?? itermPassed)
    }

    @Test func everythingReadyIsReady() {
        #expect(readiness() == .ready)
    }

    @Test func eachMissingPieceIsALineInItsCardsWords() {
        #expect(readiness(messaging: [.claude: .needsAttention("Messaging not checked for 2.1"), .codex: ready[.codex]!])
                == .notReady(["Claude Code: Messaging not checked for 2.1"]))
        #expect(readiness(cards: [.claude: card(.claude), .codex: card(.codex, integration: .missing)])
                == .notReady(["Codex: Driver is not installed"]))
        #expect(readiness(iterm: .needsAttention("iTerm2 checks not run")) == .notReady(["iTerm2 checks not run"]))
        #expect(readiness(messaging: [.claude: .needsAttention("Messaging failed: approvalRace"),
                                      .codex: .needsAttention("Messaging not checked for 0.160")],
                          iterm: .needsAttention("iTerm2 checks failed: backgroundWindow"))
                == .notReady(["Claude Code: Messaging failed: approvalRace", "Codex: Messaging not checked for 0.160",
                              "iTerm2 checks failed: backgroundWindow"]))
    }

    /// Only an installed agent the Operator chooses from is waited for: PI never is.
    @Test func onlyTheAgentsTheOperatorMayPlanOnAreWaitedFor() {
        #expect(readiness(installed: [.claude], cards: [.claude: card(.claude)], messaging: [.claude: ready[.claude]!]) == .ready)
        #expect(readiness(installed: [.claude, .pi], cards: [.claude: card(.claude)], messaging: [.claude: ready[.claude]!]) == .ready)
        #expect(readiness(installed: []) == .notReady(["No agent to plan on: install Claude Code or Codex in Settings › Agents"]))
    }

    /// Until every piece is read it is checking, unless something read already is not ready.
    @Test func itChecksUntilEveryPieceIsRead() {
        #expect(readiness(cards: [.claude: card(.claude)]) == .checking)
        #expect(readiness(messaging: [.claude: ready[.claude]!]) == .checking)
        #expect(readiness(iterm: .some(nil)) == .checking)
        #expect(readiness(cards: [.claude: card(.claude)], iterm: .needsAttention("iTerm2 checks not run"))
                == .notReady(["iTerm2 checks not run"]))
    }

    // -- the sheet ------------------------------------------------------------------------------

    private func sheet(_ readiness: @escaping @MainActor () -> BroadcastReadiness) -> NewBroadcastModel {
        let webshop = Project(id: UUID(), name: "webshop", path: "/tmp/webshop", provider: .gitlab, remoteUrl: nil, addedAt: Date(),
                              collapsed: false, jiraProjects: [])
        let model = NewBroadcastModel(projects: [webshop], context: .installed(), readiness: readiness, start: { _ in UUID() })
        model.add(project: webshop)
        model.prompt = "Implement PAY-230"
        return model
    }

    @Test func startWaitsForEveryPiece() async {
        var now = BroadcastReadiness.checking
        let model = sheet { now }
        #expect(model.canAdvance(step: 1) && model.canAdvance(step: 4), "Continue never waits")
        #expect(!model.canStart, "still checking")
        #expect(model.notReadyLines.isEmpty)
        now = .notReady(["Claude Code: Messaging not checked for 2.1", "iTerm2 checks not run"])
        #expect(!model.canStart && !model.canAdvance(step: 5))
        #expect(model.notReadyLines == ["Claude Code: Messaging not checked for 2.1", "iTerm2 checks not run"])
        #expect(await model.start() == nil)
        now = .ready
        #expect(model.canStart)
        #expect(model.notReadyLines.isEmpty)
        #expect(await model.start() != nil)
    }

    /// The app's: the Agents cards' probes of Claude Code and Codex alone, and the policy file beside the
    /// helper's others in the home, read against the installed versions the Operator is told of.
    @Test func theControllerReadsTheCardsAndThePolicyFile() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-readiness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = AppController(store: StateStore(url: home.appendingPathComponent("state.json")), preferences: .scratch(), harnessHome: home)
        controller.agents.availableAgents = [.claude, .codex, .pi]
        let service = ReadyHarnesses(snapshots: cards)
        let harness = controller.agents.harnessSettingsModel(service: service)
        #expect(controller.broadcastReadiness == .checking)

        let policy = AiTermPaths.deliveryPolicyURL(home: home)
        try FileManager.default.createDirectory(at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The scratch ports' versions: Claude Code 2.1.301, Codex 0.160.0.
        try Data(#"{"claude": {"version": "2.1.9", "pasteSafe": true, "submitSafe": true, "scenarios": {}}}"#.utf8).write(to: policy)
        let checking = Task { await controller.checkBroadcastReadiness() }
        defer { checking.cancel() }
        #expect(await eventually(describing: "both planned cards and the policy file read") {
            Set(harness.snapshots.keys) == [.claude, .codex] && controller.messaging.file != nil
        })
        #expect(controller.broadcastReadiness == .notReady(["Codex: Messaging not checked for 0.160", "iTerm2 checks not run"]))
        #expect(await service.probed.sorted { $0.rawValue < $1.rawValue } == [.claude, .codex], "PI is never planned on")
    }

    @Test func theSheetChecksAsItOpens() async {
        var checked = 0
        let model = NewBroadcastModel(projects: [], context: NewBroadcastContext(slices: .none), readiness: { .checking }, checkReadiness: { checked += 1 },
                                      start: { _ in UUID() })
        await model.checkReadiness()
        #expect(checked == 1)
        #expect(BroadcastReadiness.title == "Not ready to start")
    }
}

/// Every probe answered from `snapshots`, and which agents were probed.
private actor ReadyHarnesses: HarnessServicing {
    let snapshots: [AgentKind: HarnessSnapshot]
    private(set) var probed: [AgentKind] = []
    init(snapshots: [AgentKind: HarnessSnapshot]) { self.snapshots = snapshots }
    func probe(_ agent: AgentKind) async -> HarnessSnapshot { probed.append(agent); return snapshots[agent]! }
    func install(_ agent: AgentKind) async throws -> HarnessSnapshot { snapshots[agent]! }
    func test(_ snapshot: HarnessSnapshot) async -> HarnessSnapshot { snapshot }
}
