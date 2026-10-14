import SwiftUI
import AiTermCore
import AiTermUI

/// What New Review's footer draws around a Fix, decided from the failure and the session's state
/// alone, so every state is tested without rendering (spec §9.1, footer states 1–9 of the picked
/// design). `CreationFooter` draws it.
struct FixFooterPresentation: Equatable {
    /// What stands where the failure's sentence was.
    enum Lead: Equatable {
        /// The amber sentence, and its tooltip: git's whole output for a git failure.
        case failure(String, help: String)
        /// The agent at work: “Claude is looking at the conflict…”.
        case busy(String)
        /// The agent's plan, kept on screen while it is applied.
        case proposal(FixerAgent, FixProposal)
    }

    /// The Fix button at the footer's leading edge, after the failure's own recovery.
    struct Offer: Equatable {
        let title: String
        /// False while the agent cannot run: greyed, its tooltip saying why.
        let isEnabled: Bool
        /// Try Again: a new Look, told why the last fix failed.
        let retries: Bool
        let help: String
    }

    /// Who holds Cancel and the primary button.
    enum Buttons: Equatable {
        /// The sheet's own: Back or Cancel, and Create or Continue.
        case sheet
        /// Cancel stops the Look; the create is held.
        case looking
        /// Cancel declines; Apply on ⌘↩.
        case proposal
        /// Cancel is off and Apply turns: the fix, then the create, run as one.
        case applying
    }

    let lead: Lead?
    let offer: Offer?
    /// Whether the failure's own recovery (Rebase, Switch to main) is offered: not while a fix is
    /// at work or proposed, since its buttons have the footer then.
    let showsRecovery: Bool
    let buttons: Buttons

    /// Whether the sheet may close: not while a fix is applied, half-made.
    var canClose: Bool { buttons != .applying }

    init(error: CreationFailure?, state: FixSession.State?, fixer: FixerAgent?, lastProposal: FixProposal?) {
        let name = fixer?.shortName ?? "AI"
        func failure(_ text: String, help: String? = nil) -> Lead { .failure(text, help: help ?? text) }
        let byHand = error?.reasonByHand
        switch state {
        case .offered?:
            lead = error.map { failure($0.shownReason, help: $0.detail) }
            offer = Offer(title: "Fix with \(name)", isEnabled: true, retries: false,
                          help: "\(name) reads the problem and proposes a fix; nothing changes until you press Apply.")
            buttons = .sheet
        case .looking?:
            lead = .busy("\(name) is looking at \(error?.fix?.recreateRebase == false ? "the branch" : "the conflict")…")
            offer = nil; buttons = .looking
        case .proposal(let proposal)?:
            lead = fixer.map { .proposal($0, proposal) }
            offer = nil; buttons = .proposal
        case .applying?, .done?:
            lead = fixer.flatMap { agent in lastProposal.map { .proposal(agent, $0) } }
            offer = nil; buttons = .applying
        case .noFix(let reason)?:
            lead = failure([reason, error?.byHand].compactMap { $0 }.joined(separator: " "))
            offer = nil; buttons = .sheet
        case .failed(let reason)?:
            lead = failure(reason)
            offer = Offer(title: "Try Again", isEnabled: true, retries: true, help: "Asks \(name) for a new fix, told why this one failed.")
            buttons = .sheet
        case .unavailable(let why)?:
            lead = byHand.map { failure($0, help: error?.detail) }
            offer = why.isEmpty ? nil : Offer(title: "Fix with \(name)", isEnabled: false, retries: false, help: why)
            buttons = .sheet
        case nil:
            lead = byHand.map { failure($0, help: error?.detail) }
            offer = nil; buttons = .sheet
        }
        showsRecovery = error?.recovery != nil && buttons == .sheet
    }
}

/// What the banner above the list draws for a failed operation and the Fix it offers, decided
/// from the issue and the session's state alone, so every state is tested without rendering
/// (spec §9.1, banner states 1–5 of the picked design). `IssueBanner` draws it.
struct BannerFixPresentation: Equatable {
    /// What stands where the issue's sentence was.
    enum Content: Equatable {
        /// The issue's title, then `detail` after it in muted ink; `help`, git's whole output, in the tooltip.
        case text(String, detail: String?, help: String?)
        /// The agent at work: “Claude is looking at “Couldn’t rebase the default branch”…”.
        case busy(String)
        /// The agent's plan, waiting on Apply.
        case proposal(FixerAgent, FixProposal)
    }

    /// The banner's links, in order.
    enum Link: Equatable {
        /// One of the issue's own ways out: Rebase, Keep Branch…
        case action(OperationIssue.Action)
        /// The offer — greyed, its tooltip saying why, while the agent cannot run.
        case fix(title: String, isEnabled: Bool, help: String)
        /// A new Look, told why the last fix failed.
        case tryAgain(help: String)
        case apply(help: String)
        /// Stops the Look or declines the proposal; greyed while the fix is applied.
        case cancel(isEnabled: Bool)
        case dismiss

        var title: String {
            switch self {
            case .action(let action): action.title
            case .fix(let title, _, _): title
            case .tryAgain: "Try Again"
            case .apply: "Apply"
            case .cancel: "Cancel"
            case .dismiss: "Dismiss"
            }
        }
    }

    let content: Content
    let links: [Link]

    /// Whether Dismiss is there: not while the fix holds the banner.
    var canDismiss: Bool { links.contains(.dismiss) }

    init(issue: OperationIssue, state: FixSession.State?, fixer: FixerAgent?) {
        let name = fixer?.shortName ?? "AI"
        // What sent the person to a terminal, dropped while the Fix is the way out: back when no fix can help.
        let byHand = issue.fix?.recreateRebase == true ? WorktreeError.rebaseByHand : nil
        func text(_ parts: String?...) -> Content {
            let detail = parts.compactMap { $0 }.joined(separator: " ")
            return .text(issue.title, detail: detail.isEmpty ? nil : detail, help: issue.detail)
        }
        let own = issue.actions.map(Link.action)
        switch state {
        case .offered?:
            content = text(issue.reason)
            links = own + [.fix(title: "Fix with \(name)", isEnabled: true,
                                help: "\(name) reads the problem and proposes a fix; nothing changes until you press Apply."), .dismiss]
        case .looking?:
            let title = issue.title.trimmingCharacters(in: .punctuationCharacters)
            content = .busy("\(name) is looking at “\(title)”…")
            links = [.cancel(isEnabled: true)]
        case .proposal(let proposal)?:
            content = fixer.map { .proposal($0, proposal) } ?? text(issue.reason)
            let again = issue.fix.map { "then pulls \($0.branch) again" } ?? "then runs what failed again"
            links = [.apply(help: "Applies \(name)’s fix, \(again)."), .cancel(isEnabled: true)]
        // The moment between landing and the pull is drawn as applying: the old issue must not flash back.
        case .applying?, .done?:
            content = .busy("Applying \(name)’s fix…")
            links = [.cancel(isEnabled: false)]
        case .noFix(let reason)?:
            content = text(reason, byHand)
            links = own + [.dismiss]
        case .failed(let reason)?:
            content = text(reason)
            links = own + [.tryAgain(help: "Asks \(name) for a new fix, told why this one failed."), .dismiss]
        case .unavailable(let why)?:
            content = text(issue.reason, byHand)
            links = own + (why.isEmpty ? [] : [.fix(title: "Fix with \(name)", isEnabled: false, help: why)]) + [.dismiss]
        case nil:
            content = text(issue.reason, byHand)
            links = own + [.dismiss]
        }
    }
}

/// The agent's proposal where the failure was (decision 2A): its `VendorMark`, what it found in
/// `Typography.label`, why in `caption` and `Palette.muted`, and its numbered steps in `help`, each
/// hanging after its number. `compact` is the banner's sizes: why in `help` too.
struct FixProposalBlock: View {
    let agent: FixerAgent
    let proposal: FixProposal
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.base) {
            VendorMark(agent: agent.agent.session, size: Size.vendorMark)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(proposal.headline).font(Typography.label).foregroundStyle(Palette.text)
                Text(proposal.why).font(compact ? Typography.help : Typography.caption).foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: Space.hairline) {
                    ForEach(Array(proposal.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            // The list's indent: the number hangs in it, as an ordered list's marker does.
                            Text("\(index + 1).").frame(width: Space.block, alignment: .leading)
                            Text(step)
                        }
                        .font(Typography.help).foregroundStyle(Palette.muted)
                    }
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// “Claude is looking at the conflict…”: a working `StatusMark` and the line. `compact` is the
/// banner's size: the line in `help`, as the banner's text is.
struct FixBusyLine: View {
    let text: String
    var compact = false

    var body: some View {
        HStack(spacing: Space.snug) {
            StatusMark(status: .working, size: Size.statusMark)
            Text(text).font(compact ? Typography.help : Typography.caption).foregroundStyle(Palette.muted)
        }
    }
}
