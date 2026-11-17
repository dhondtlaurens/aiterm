import SwiftUI
import AiTermCore
import AiTermUI

enum HarnessCardPresentation {
    static let agents = AgentKind.allCases

    /// The CLI, the driver and, on Claude Code's and Codex's cards, Messaging. Models stay out: the
    /// picker below carries an empty catalogue, and the opening test's daemon and delivery checks
    /// reach the user through the status sentence.
    static func chips(for snapshot: HarnessSnapshot) -> [HarnessCheck] {
        snapshot.checks.filter { [.cli, .integration, .messaging].contains($0.id) }
    }

    /// The card as it is drawn: the probe's snapshot with Messaging added (`MessagingChecks`), one more
    /// check that Install cannot fix, after the others so a missing CLI or driver is said first. Its
    /// sentence is the chip's tooltip while it passes and the status line while it is what needs
    /// attention. `runFailure` is why the last Run check could not open its window; while one `running`
    /// has not written its verdict, the card says so in place of the last. Left as it is over a missing
    /// CLI, for an agent the check does not cover, and until the file is read.
    static func snapshot(_ snapshot: HarnessSnapshot, messaging: DeliveryReadiness?, runFailure: String? = nil,
                         running: Bool = false) -> HarnessSnapshot {
        guard snapshot.health != .unavailable, let messaging else { return snapshot }
        var checks = snapshot.checks.filter { $0.id != .messaging }
        if let runFailure { checks.insert(HarnessCheck(.operation, passed: false, explanation: runFailure, repairable: false), at: 0) }
        let sentence = running && !messaging.isReady ? checkRunning : messaging.sentence
        checks.append(HarnessCheck(.messaging, passed: messaging.isReady, explanation: sentence, repairable: false))
        return .reduce(agent: snapshot.agent, cliAvailable: true, integrationState: snapshot.integrationState,
                       models: snapshot.models, modelsAreStale: snapshot.modelsAreStale, checks: checks)
    }

    /// The card's action while Messaging is what needs attention: the delivery check, in an iTerm2 window.
    static let runCheck = "Run check"
    /// Messaging's sentence while Run check's window is at work.
    static let checkRunning = "Check running in iTerm2"

    static func status(for snapshot: HarnessSnapshot) -> SettingsStatus {
        // A passing test confirms the probe, so the label holds at "Ready" through the spinner and
        // after it; only a failure changes what the card says.
        switch snapshot.health {
        case .ready: return SettingsStatus(.ready, "Ready")
        case .warning: return SettingsStatus(.attention, snapshot.summary)
        // A missing CLI is a neutral fact until installing it fails; then it needs attention.
        case .unavailable:
            return SettingsStatus(snapshot.checks.contains { $0.id == .operation } ? .attention : .idle,
                                  snapshot.summary)
        }
    }

    /// The card's one action, named for what it will do here; every label runs the same install.
    /// Install while the CLI or the driver is missing, Repair while a check is amber, Reinstall
    /// over a card that is Ready. No action while the only amber check is one Install cannot fix:
    /// the button would run, write nothing and leave the card as it was; Run check instead, when
    /// Messaging is among them.
    static func action(for snapshot: HarnessSnapshot) -> String? {
        if snapshot.installChangesNothing {
            return snapshot.checks.contains { $0.id == .messaging && !$0.passed } ? runCheck : nil
        }
        if snapshot.health == .unavailable || snapshot.integrationState == .missing { return "Install" }
        return snapshot.health == .ready ? "Reinstall" : "Repair"
    }


}

struct HarnessSettingsPane: View {
    let model: HarnessSettingsModel
    /// Claude Code's configuration path, shown on its card.
    let agents: AgentIntegrations
    /// Each card's Messaging, and its Run check; its versions are also what the verified line reads.
    var messaging = MessagingChecks.inert()
    /// The CLI versions this build was checked with, for each card's muted line.
    var verified = CompatVerified(lines: [:])
    /// The card Settings was opened at (`SheetCoordinator.presentSettings(tab:agent:)`), scrolled to once
    /// its probe has drawn it, through the sheet's scroll view.
    var focus: AgentKind?
    var scroll: ScrollViewProxy?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            ForEach(HarnessCardPresentation.agents, id: \.self) { agent in
                if let snapshot = model.snapshots[agent] {
                    card(HarnessCardPresentation.snapshot(snapshot, messaging: messaging.readiness(of: agent),
                                                          runFailure: messaging.failures[agent],
                                                          running: messaging.isRunning(agent)))
                        .id(agent)
                        .accessibilityIdentifier("harness-card-\(agent.rawValue)")
                }
            }
            HelpText("Claude Code and Codex are fully supported; other providers, such as Grok, work through PI. Settings tests each agent when it opens. Install adds a missing CLI with its vendor’s own installer, then AiTerm’s driver; Run check opens iTerm2 to check that AiTerm can message the agent. Install and Run check take effect immediately; Cancel does not undo them.")
        }
        .onChange(of: focus.map { model.snapshots[$0] != nil } ?? false, initial: true) { _, drawn in
            if drawn, let focus { scroll?.scrollTo(focus, anchor: .top) }
        }
    }

    private func card(_ snapshot: HarnessSnapshot) -> some View {
        SettingsCard(title: snapshot.agent.displayName, status: HarnessCardPresentation.status(for: snapshot)) {
            VendorMark(agent: snapshot.agent.session, size: Size.control)
        } chips: {
            ForEach(HarnessCardPresentation.chips(for: snapshot), id: \.id) { check in
                CheckChip(label: check.label, passed: check.passed, help: check.explanation)
            }
        } actions: {
            actions(snapshot)
        } content: {
            if snapshot.health != .unavailable,
               let line = verified.sentence(for: snapshot.agent, installed: messaging.versions[snapshot.agent]) {
                HelpText(line)
                    .accessibilityIdentifier("verified-\(snapshot.agent.rawValue)")
            }
            if snapshot.agent == .claude, let path = agents.claudeConfigPath {
                HelpText("Configuration: \(path)")
            }
            if !messaging.isRunning(snapshot.agent), let failure = messaging.failure(of: snapshot.agent) {
                CheckFailureDetails(failure: failure)
                    .accessibilityIdentifier("check-failure-\(snapshot.agent.rawValue)")
            }
            defaults(snapshot)
        }
    }

    @ViewBuilder
    private func actions(_ snapshot: HarnessSnapshot) -> some View {
        if model.running.contains(snapshot.agent) || messaging.isRunning(snapshot.agent) {
            ProgressView().controlSize(.small)
        }
        // On every card but one whose only warning Install cannot fix, so a working driver can be
        // overwritten on purpose and a missing CLI installed. Disabled only where the file is not
        // AiTerm's to replace. Run check while Messaging is what needs attention.
        if let action = HarnessCardPresentation.action(for: snapshot), action == HarnessCardPresentation.runCheck {
            Button(action) { Task { await messaging.run(snapshot.agent) } }
                .disabled(messaging.opening.contains(snapshot.agent))
                .help("Opens iTerm2 and runs AiTerm’s delivery check for \(snapshot.agent.displayName), which takes a few minutes. Running it again starts over.")
        } else if let action = HarnessCardPresentation.action(for: snapshot) {
            Button(action) { Task { await model.install(snapshot.agent) } }
                .disabled(model.running.contains(snapshot.agent) || !snapshot.canInstall)
                .help(snapshot.health == .unavailable
                      ? "Runs \(snapshot.agent.harness.installCommand), then installs AiTerm’s driver." : "")
        }
    }

    @ViewBuilder
    private func defaults(_ snapshot: HarnessSnapshot) -> some View {
        if snapshot.models.isEmpty && model.preferences[snapshot.agent]?.model.isEmpty != false {
            HelpText(snapshot.agent.harness.noModelsExplanation)
        } else {
            let preference = model.preferences[snapshot.agent]
            let selected = preference?.model ?? snapshot.models.first?.id ?? ""
            VStack(alignment: .leading, spacing: Space.base) {
                ModelReasoningFields(
                    models: snapshot.models, model: selected,
                    reasoning: Binding(get: { preference?.reasoning },
                                       set: { if let value = $0 { model.selectReasoning(value, for: snapshot.agent) } }),
                    prefix: "Default ", disabled: snapshot.modelsAreStale,
                    reasoningOptions: snapshot.models.first { $0.id == preference?.model }?.efforts ?? [],
                    selectModel: { model.select($0, for: snapshot.agent) })
                if snapshot.modelsAreStale {
                    HelpText("Showing the last verified model catalogue.")
                }
                if preference != nil && !snapshot.models.contains(where: { $0.id == preference?.model }) {
                    HelpText(ModelReasoningFields.unavailableHelp, tone: .warning)
                }
            }
        }
    }
}

/// Why the delivery check's last run failed, on the card whose Messaging it failed: folded, a chevron
/// and “Why it failed” in muted ink, as a project header folds; unfolded, the reason and the end of
/// the screen it read, as the check's window said them, in `Typography.mono`, selectable to copy.
struct CheckFailureDetails: View {
    static let title = "Why it failed"

    let failure: String
    @State private var open: Bool

    init(failure: String) {
        self.failure = failure
        _open = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Button { open.toggle() } label: {
                HStack(spacing: Space.tight) {
                    HeaderChevron(collapsed: !open)
                    Text(Self.title).font(Typography.caption)
                }
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(failure).font(Typography.mono).foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// The Mac and agent cards use the same check status and ink.
struct CheckChip: View {
    let label: String
    let passed: Bool
    var help: String? = nil

    var body: some View {
        Badge(label, icon: .symbol(passed ? "checkmark" : "exclamationmark"),
              help: help, iconTint: passed ? Palette.green : Palette.amber)
    }
}
