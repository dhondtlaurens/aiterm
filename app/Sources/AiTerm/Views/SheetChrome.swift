import SwiftUI
import AiTermUI
import AiTermCore

extension DismissAction {
    /// Dismisses on the next main-actor turn rather than inside the event that asked — a click, ⎋,
    /// or ⌘↩ on the primary button; every sheet closes this way. Presented, as the app presents its
    /// sheets, either closes the sheet. Hosted in a plain window, as the tests host them, a dismiss
    /// inside the event closes that window under the event, and a window that releases itself on
    /// close takes the process down with it (`SheetDismissalTests`).
    @MainActor func afterThisEvent() { Task { self() } }
}

/// Shared modal chrome: navigation stays above the scrolling content and actions stay below it.
struct SheetLayout<Navigation: View, Content: View, Footer: View>: View {
    let title: String
    let height: CGFloat
    /// The band's height: `Size.control` for a step bar, a tab bar or a subtitle; nil for a band of lines
    /// that sizes itself (the board's status and header lines over its tab bar), `Space.base` under the title.
    let bandHeight: CGFloat?
    /// The axes the content scrolls on, as one, between the rules and from edge to edge, its margins inside the
    /// scroll: down for a form, down and sideways for the board's row of columns.
    let scrolls: Axis.Set
    /// The content's inset from the rules above and below it: a sheet's margin, or less for a list of
    /// rows whose own pills already pad them (the Archive sheet's).
    let contentVerticalPadding: CGFloat
    let onBackgroundTap: (() -> Void)?
    #if DEBUG
    @Environment(\.snapshotRendering) private var isSnapshot
    #else
    private let isSnapshot = false
    #endif
    let navigation: Navigation
    let content: Content
    let footer: Footer

    init(title: String, height: CGFloat, bandHeight: CGFloat? = Size.control, scrolls: Axis.Set = .vertical,
         contentVerticalPadding: CGFloat = Space.margin, onBackgroundTap: (() -> Void)? = nil,
         @ViewBuilder navigation: () -> Navigation,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.height = height
        self.bandHeight = bandHeight
        self.scrolls = scrolls
        self.contentVerticalPadding = contentVerticalPadding
        self.onBackgroundTap = onBackgroundTap
        self.navigation = navigation()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: bandHeight == nil ? Space.base : Space.block) {
                Text(title).font(Typography.title).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.middle).help(title)
                if let bandHeight { navigation.frame(height: bandHeight) } else { navigation }
            }
            .padding(.horizontal, Space.margin).padding(.top, Space.section).padding(.bottom, Space.block)
            Hairline()
            Group {
                if isSnapshot {
                    // ImageRenderer cannot materialise a ScrollView’s contents: what lies past the edges is cut. A sideways
                    // scroll's content is laid out whole first, so it is cut rather than squeezed; `minWidth: 0`, or the
                    // frame would be as wide as that content and widen the sheet.
                    paddedContent.fixedSize(horizontal: scrolls.contains(.horizontal), vertical: false)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                } else {
                    ScrollView(scrolls) { paddedContent }.scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            footer
                .padding(.horizontal, Space.margin).padding(.vertical, Space.block)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceRaised)
        }
        .frame(width: Sheet.width, height: Sheet.fittingHeight(height))
        .background {
            if let onBackgroundTap {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onBackgroundTap)
            }
        }
        .background(Palette.surface)
    }

    private var paddedContent: some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Space.margin).padding(.vertical, contentVerticalPadding)
    }
}

/// The band under a sheet's title, on a sheet with no steps and no tabs: one sentence saying what
/// the sheet does. Never a path — where a sheet opens is its `DestinationLine`, at the foot of its
/// content.
struct SheetSubtitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Typography.caption).foregroundStyle(Palette.muted)
            .lineLimit(1).truncationMode(.tail).help(text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sheet's primary action: the prominent button, answering ⌘↩ and only ⌘↩ — the keycaps it shows.
/// A plain ⏎ stays with the focused control: a newline in the prompt editor, a pick in a dropdown.
/// `busy` leads its title with a working `StatusMark` while what it started runs — New Review's
/// Apply; the caller's action guards itself meanwhile, as Back does while a create runs.
struct SheetPrimaryButton: View {
    let title: String
    var enabled = true
    var busy = false
    var help: String?
    let action: () -> Void

    var body: some View {
        button.help(help ?? "")
    }

    private var button: some View {
        // The label sits on the accent fill, and says so: the keycaps and the mark read it.
        Button(action: action) {
            HStack(spacing: Space.base) {
                HStack(spacing: Space.snug) {
                    if busy { StatusMark(status: .working, size: Size.statusMark) }
                    Text(title)
                }
                Kbd("⌘", "↩")
            }
            .surface(.accent)
        }
        .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
        .disabled(!enabled)
    }
}

/// The foot of every sheet: Cancel — or Back, whatever `secondary` says — and the primary action
/// at the trailing edge, with optional `status` text before them. A nil `secondary` or `primary` is
/// an action the sheet does not offer at that moment, absent rather than disabled: the Backpack
/// sheet has only Cancel while it connects, and only Done once it is safe.
///
/// ⎋ is a hidden button of its own, not Cancel's key: an open list closes first — a button's key
/// equivalent would beat the field's own ⎋, and in every other app that list is a window of its own,
/// so closing the whole sheet is not what the key means there — and *clicking* Cancel still cancels.
/// `closeList` closes one and says whether there was one to close — a picker's results, or the
/// prompt editor's completion popup, whose own ⎋ the hidden button hears first; a sheet with no
/// lists needs nothing, and ⎋ is Cancel. `cancel` guards itself when it must, as Back does while a create runs.
/// With no `secondary` there is nothing for ⎋ to do, and it does nothing.
///
/// A pattern, not a primitive: it encodes where *this app* puts a sheet's actions.
struct SheetFooter<Status: View>: View {
    let secondary: String?
    let primary: String?
    let canCancel: Bool
    let canSubmit: Bool
    /// The primary's working mark and tooltip (`SheetPrimaryButton`).
    let primaryBusy: Bool
    let primaryHelp: String?
    let closeList: () -> Bool
    let cancel: () -> Void
    let submit: () -> Void
    let status: Status

    init(secondary: String? = "Cancel", primary: String?, canCancel: Bool = true, canSubmit: Bool = true,
         primaryBusy: Bool = false, primaryHelp: String? = nil,
         closeList: @escaping () -> Bool = { false }, cancel: @escaping () -> Void, submit: @escaping () -> Void,
         @ViewBuilder status: () -> Status = { EmptyView() }) {
        self.secondary = secondary; self.primary = primary; self.canCancel = canCancel; self.canSubmit = canSubmit
        self.primaryBusy = primaryBusy; self.primaryHelp = primaryHelp
        self.closeList = closeList; self.cancel = cancel; self.submit = submit; self.status = status()
    }

    var body: some View {
        HStack(spacing: Space.base) {
            status
            Spacer(minLength: Space.base)
            if let secondary { Button(secondary, action: cancel).disabled(!canCancel) }
            if let primary {
                SheetPrimaryButton(title: primary, enabled: canSubmit, busy: primaryBusy, help: primaryHelp, action: submit)
            }
        }
        .controlSize(.large)
        .overlay {
            if secondary != nil { Button("Close") { if !closeList() { cancel() } }.keyboardShortcut(.cancelAction).hidden() }
        }
    }
}

/// The footer every creation sheet shares (New Task, New Review, New Broadcast): the last failure,
/// why no agent can run, and a `SheetFooter` — Back, or Cancel on the first step, and Continue or
/// the create button on the last (`CreationSteps`). A failure
/// with a fix (`CreationFailure.recovery`) offers it at the leading edge, in the footer's `status`
/// slot: a plain button with no key, since it moves a branch — ⌘↩ stays the create.
///
/// A failure is a `Notice` with no actions — the footer's buttons are its actions — and shows its
/// reason, never the head of git's output: that is the command line and git's narration, and three
/// lines of it used to be all there was room for. The reason is git's failure lines as one sentence
/// (`GitError.sentence`), or any other error's own, as the banner has it — short by construction, so
/// it is never cut, and the Notice's title alone; git's whole output is the tooltip.
///
/// A failure an agent can fix (`fix`, New Review's) offers Find a Fix after the recovery, led by the
/// Operator's mark; from then on the session's state is drawn where the failure was, and takes
/// Cancel and the primary while the agent looks, proposes — Apply on ⌘↩ — and applies
/// (`FixFooterPresentation`). A fix that fails keeps the failure's sentence as the title, with why
/// it failed as the description.
struct CreationFooter: View {
    let step: Int
    /// How many steps there are and which picks the agent: New Task's and New Review's three unless told.
    var steps = CreationSteps(count: 3, agentStep: 2)
    let error: CreationFailure?
    let availableAgents: Set<AgentKind>
    let createLabel: String
    let creating: Bool
    let canAdvance: Bool
    let closeList: () -> Bool
    let back: () -> Void
    let advance: () -> Void
    /// The failure's fix, then the create it stopped.
    let recover: () -> Void
    /// The Fix offered for the failure, if any; its state is the one thing here it observes.
    var fix: FixSession? = nil
    /// Whether Apply may run: the workspace can change, so the create after the fix can too.
    var canApply = true
    /// Apply on the proposal that is up.
    var applyFix: () -> Void = {}
    /// What the create waits for, one line each, under a title: New Broadcast's `BroadcastReadiness`.
    /// A Notice with no actions, as a failure is; none while nothing waits.
    var waiting: (title: String, lines: [String])? = nil

    var body: some View {
        let state = fix?.state
        // Read only while it is drawn: it is never cleared, so in any other state it is stale.
        let applied: FixProposal? = switch state { case .applying?, .done?: fix?.lastProposal; default: nil }
        let shown = FixFooterPresentation(error: error, state: state, fixer: fix?.fixer, lastProposal: applied)
        VStack(alignment: .leading, spacing: Space.gap) {
            switch shown.lead {
            case .failure(let text, let description, let help)?:
                Notice(title: text, description: description, help: help)
            case .busy(let text)?: FixBusyLine(text: text)
            case .proposal(let agent, let proposal)?: FixProposalBlock(agent: agent, proposal: proposal)
            case nil: EmptyView()
            }
            if steps.saysNoAgentCanRun(onStep: step), availableAgents.isEmpty, let note = AgentStep.missingAgentNote(available: availableAgents) {
                Notice(title: note)
            }
            if let waiting, !waiting.lines.isEmpty {
                Notice(title: waiting.title, description: waiting.lines.joined(separator: "\n"))
            }
            SheetFooter(secondary: shown.buttons == .sheet ? steps.secondaryTitle(onStep: step) : "Cancel",
                        primary: primaryTitle(shown.buttons),
                        canCancel: shown.buttons == .applying ? false : !creating,
                        canSubmit: canSubmit(shown.buttons),
                        primaryBusy: shown.buttons == .applying,
                        primaryHelp: shown.buttons == .proposal ? "Applies \(fix?.fixer?.shortName ?? "the agent")’s fix, then creates the review." : nil,
                        closeList: closeList,
                        // While a fix holds the buttons, Cancel — and ⎋ — are its: they stop a Look,
                        // decline a proposal, and do nothing while it is applied. ⌘↩ is Apply only
                        // on a proposal; while it is applied, nothing.
                        cancel: shown.buttons == .sheet ? back : { fix?.cancel() },
                        submit: submit(shown.buttons)) {
                if shown.showsRecovery, let recovery = error?.recovery {
                    Button(recovery.title, action: recover).help(recovery.help).disabled(creating)
                }
                if let offer = shown.offer {
                    Button { offer.retries ? fix?.tryAgain() : fix?.start() } label: {
                        if offer.retries { Text(offer.title) } else { FixOfferLabel() }
                    }
                    .help(offer.help).disabled(!offer.isEnabled || creating)
                }
                if shown.buttons == .applying {
                    Text("Applying…").font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func canSubmit(_ buttons: FixFooterPresentation.Buttons) -> Bool {
        switch buttons {
        case .sheet: canAdvance
        case .looking: false
        case .proposal: canApply
        // Drawn as the mock has it, turning and not dimmed; `submit` makes it do nothing.
        case .applying: true
        }
    }

    private func submit(_ buttons: FixFooterPresentation.Buttons) -> () -> Void {
        switch buttons {
        case .sheet, .looking: advance
        case .proposal: applyFix
        case .applying: {}
        }
    }

    private func primaryTitle(_ buttons: FixFooterPresentation.Buttons) -> String {
        switch buttons {
        case .proposal, .applying: "Apply"
        case .sheet, .looking: steps.primaryTitle(onStep: step, createLabel: createLabel)
        }
    }
}

/// 1 Task —— 2 Agent —— 3 Prompt, spread across the full width of the header: the connectors
/// stretch, so the steps sit evenly from the left edge to the right rather than bunching up. New
/// Broadcast's four (Broadcast · Prompt · Review · Done) are drawn the same; no step name is a button.
struct StepBar: View {
    let step: Int
    /// New Task's first step names a ticket; New Review's names a branch; New Broadcast has four.
    /// Everything else about the bar is identical, so the names are the only thing that varies.
    let names: [String]

    var body: some View {
        HStack(spacing: Space.base) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let number = index + 1
                HStack(spacing: Space.snug) {
                    ZStack {
                        Circle().fill(fill(number))
                        Text("\(number)").font(Typography.micro)
                            .foregroundStyle(number == step ? Surface.accent.ink : (number < step ? Palette.text : Palette.muted))
                    }
                    .frame(width: Size.avatar, height: Size.avatar)
                    .overlay(Circle().strokeBorder(number > step ? Palette.border : .clear, lineWidth: 1))
                    Text(name).font(Typography.caption).foregroundStyle(number == step ? Palette.text : Palette.muted)
                }
                .fixedSize()
                if number < names.count {
                    Hairline().frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func fill(_ number: Int) -> Color {
        if number == step { return Palette.accent }
        if number < step { return Palette.controlActive }
        return Palette.surface
    }
}

/// Claude Code / Codex, with the vendor marks. An agent whose CLI is not on the login shell's
/// `PATH` cannot be picked, and says so.
struct AgentSegmented: View {
    let agents: [AgentKind]
    let available: Set<AgentKind>
    @Binding var selection: AgentKind

    /// Only an installed CLI can be picked. With none installed every segment is disabled: each
    /// would open a window that prints "command not found". An unknown answer — the login shell
    /// failed — arrives here as every agent, never as none (`AgentIntegrations.availableAgents`).
    static func isSelectable(_ agent: AgentKind, available: Set<AgentKind>) -> Bool { available.contains(agent) }

    var body: some View {
        SegmentedControl(values: agents, selection: $selection,
                       isSelectable: { Self.isSelectable($0, available: available) },
                       help: { Self.isSelectable($0, available: available)
                           ? nil : "\($0.displayName) isn’t installed. Install it in Settings › Agents." }) { agent, on in
            AgentSegmentLabel(agent: agent, on: on)
        }
    }
}

/// An agent's segment: its vendor mark and name, the name in the emphasised weight while selected.
struct AgentSegmentLabel: View {
    let agent: AgentKind
    let on: Bool

    var body: some View {
        HStack(spacing: Space.snug) {
            VendorMark(agent: agent.session, size: Size.vendorMark)
            Text(agent.displayName).font(on ? Typography.bodyEmphasis : Typography.body)
        }
    }
}

/// The exact command the task will run, on one line, with the whole thing in the tooltip.
struct CommandBlock: View {
    let caption: String
    let command: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HelpText(caption, fixedVerticalSize: false).lineLimit(1).truncationMode(.middle)
            HStack(spacing: Space.snug) {
                Text("$").font(Typography.monoCode).foregroundStyle(Palette.green)
                Text(String(command.prefix(300))).font(Typography.monoCode).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.inset).padding(.vertical, Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.codeBackground))
            .help(command)
        }
    }
}
