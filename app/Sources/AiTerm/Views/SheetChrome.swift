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

/// How tall a sheet is: a fixed height — a flow whose steps must not jump, a sheet whose content scrolls
/// — or as tall as its content up to a most, a sheet of a few fields that would otherwise stand in empty
/// space. Either way never taller than the screen allows (`Sheet.fittingHeight`).
enum SheetHeight: Equatable {
    case fixed(CGFloat)
    /// The content's own height, scrolling only past `upTo`. The sheet follows its content as it
    /// changes, so a fixed content keeps one height for as long as it is open.
    case fitting(upTo: CGFloat)
}

/// Shared modal chrome: a header over the scrolling content and the actions below it. The whole sheet,
/// footer included, is on the sheet's own ground (`Palette.surface`); a hairline under the header and one
/// over the footer set the content off.
///
/// The header is the title row — the title in `Typography.title`, cut in the middle, and an optional
/// trailing `accessory` (a stepped sheet's `SheetStepper`) that never gives way to it — then the optional
/// `header` content `Space.tight` under it: a `SheetSubtitle`, the Shelf's search field, the board's
/// lines and tabs, Settings' tabs. It is `Space.section` from the top and `Space.margin` from the sides,
/// and `Space.block` from its rule, except when its last line is a `TabBar` (`headerEndsInTabs`): then the
/// tabs stand on the rule and the selected one's underline covers it.
struct SheetLayout<Accessory: View, Header: View, Content: View, Footer: View>: View {
    let title: String
    let height: SheetHeight
    /// The header ends in a `TabBar`, whose selected underline lies on the header's rule.
    let headerEndsInTabs: Bool
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
    let accessory: Accessory
    let header: Header
    let content: Content
    let footer: Footer

    init(title: String, height: SheetHeight, headerEndsInTabs: Bool = false, scrolls: Axis.Set = .vertical,
         contentVerticalPadding: CGFloat = Space.margin, onBackgroundTap: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.height = height
        self.headerEndsInTabs = headerEndsInTabs
        self.scrolls = scrolls
        self.contentVerticalPadding = contentVerticalPadding
        self.onBackgroundTap = onBackgroundTap
        self.accessory = accessory()
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        SheetStack(width: Sheet.width, height: resolvedHeight) {
            headerBlock
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
            VStack(spacing: 0) {
                Hairline()
                footer
                    .padding(.horizontal, Space.margin).padding(.vertical, Space.block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.surface)
        }
        .background {
            if let onBackgroundTap {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onBackgroundTap)
            }
        }
        .background(Palette.surface)
    }

    /// The height `SheetStack` lays the sheet out at, the screen's limit applied here, on the main actor.
    private var resolvedHeight: SheetHeight {
        switch height {
        case .fixed(let preferred): .fixed(Sheet.fittingHeight(preferred))
        case .fitting(let most): .fitting(upTo: Sheet.fittingHeight(most))
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.gap) {
                Text(title).font(Typography.title).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.middle).help(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory.fixedSize().layoutPriority(1)
            }
            header
        }
        .padding(.horizontal, Space.margin).padding(.top, Space.section)
        .padding(.bottom, headerEndsInTabs ? 0 : Space.block)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Behind the header, so a tab's underline is drawn over it.
        .background(alignment: .bottom) { Hairline() }
    }

    private var paddedContent: some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Space.margin).padding(.vertical, contentVerticalPadding)
    }
}

extension SheetLayout where Accessory == EmptyView {
    /// A sheet with no steps: its title, and what its header shows under it.
    init(title: String, height: SheetHeight, headerEndsInTabs: Bool = false, scrolls: Axis.Set = .vertical,
         contentVerticalPadding: CGFloat = Space.margin, onBackgroundTap: (() -> Void)? = nil,
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.init(title: title, height: height, headerEndsInTabs: headerEndsInTabs, scrolls: scrolls,
                  contentVerticalPadding: contentVerticalPadding, onBackgroundTap: onBackgroundTap,
                  accessory: { EmptyView() }, header: header, content: content, footer: footer)
    }
}

/// A sheet's three parts top to bottom — header, content, footer — the header and footer at their own
/// heights and the content in what is left. Fixed, the sheet is that tall whatever it holds. Fitting, it is
/// the three parts' own heights added up, the content's measured as it would lie unscrolled, but never more
/// than the most: past that the content scrolls in the room left to it.
struct SheetStack: Layout {
    let width: CGFloat
    /// Already fitted to the screen.
    let height: SheetHeight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width, height: sheetHeight(subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let header = ownHeight(subviews[0]), footer = ownHeight(subviews[2])
        let content = max(0, bounds.height - header - footer)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: header))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + header),
                          proposal: ProposedViewSize(width: bounds.width, height: content))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - footer),
                          proposal: ProposedViewSize(width: bounds.width, height: footer))
    }

    /// The sheet's height for these parts.
    func sheetHeight(_ subviews: Subviews) -> CGFloat {
        switch height {
        case .fixed(let fixed): return fixed
        case .fitting(let most):
            guard subviews.count == 3 else { return most }
            return min(most, subviews.reduce(0) { $0 + ownHeight($1) })
        }
    }

    /// A part's height at the sheet's width, as it would lie with no limit on it.
    private func ownHeight(_ subview: LayoutSubview) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
}

/// The line under a sheet's title, on a sheet with no steps and no tabs: one sentence saying what
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

/// A sheet's primary action: the house primary button (`PushButtonStyle`), answering ⌘↩ and only ⌘↩ — the keycaps it shows.
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
        // The style draws the label on the accent and declares it, so the keycaps and the mark ink for it.
        Button(action: action) {
            HStack(spacing: Space.base) {
                HStack(spacing: Space.snug) {
                    if busy { StatusMark(status: .working, size: Size.statusMark) }
                    Text(title)
                }
                Kbd("⌘", "↩")
            }
        }
        .keyboardShortcut(.return, modifiers: .command).buttonStyle(.push(.primary))
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
/// Every button in it is the house push button: Cancel or Back, and whatever `status` carries (a failure's
/// recovery, Find a Fix, the board's leading actions), secondary; the primary, primary.
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
        .buttonStyle(.push(.secondary))
        .overlay {
            if secondary != nil { Button("Close") { if !closeList() { cancel() } }.keyboardShortcut(.cancelAction).hidden() }
        }
    }
}

/// The footer every creation sheet shares (New Task, New Review, New Broadcast): the last failure,
/// why no agent can run, and a `SheetFooter` — Back, or Cancel on the first step, and Continue or
/// the create button on the last (`CreationSteps`). A failure
/// with a fix (`CreationFailure.recovery`) offers it at the leading edge, in the footer's `status`
/// slot: a secondary push button with no key, since it moves a branch — ⌘↩ stays the create.
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

/// A stepped sheet's steps, at the trailing edge of its title row: ✓ —— **2 Agent** —— 3. Each step a
/// `Size.chip` circle; the current one filled in `Palette.text` with its number in the sheet's own ground,
/// its name after it in `Typography.label`; an earlier one a `Palette.borderStrong` ring round a check in
/// `Palette.muted`; a later one the ring round its number in `Palette.tertiary`. A firm `Hairline`
/// `Space.gap` long joins them, `Space.base` clear either side. No accent: it says where you are, and is
/// not navigation, so no step is a button. VoiceOver reads it as one element, "Step 2 of 3, Agent".
/// New Task's and New Review's three and New Broadcast's five are drawn the same.
struct SheetStepper: View {
    let step: Int
    /// New Task's first step names a ticket; New Review's names a branch; New Broadcast has five.
    let names: [String]

    /// How a step is drawn.
    enum Mark: Equatable {
        /// Behind the current step: a check.
        case done
        /// The step you are on, with its name.
        case current(String)
        /// Still to come: its number.
        case ahead(Int)
    }

    static func marks(step: Int, names: [String]) -> [Mark] {
        names.enumerated().map { index, name in
            let number = index + 1
            if number < step { return .done }
            if number == step { return .current(name) }
            return .ahead(number)
        }
    }

    static func accessibilityLabel(step: Int, names: [String]) -> String {
        let name = names.indices.contains(step - 1) ? ", \(names[step - 1])" : ""
        return "Step \(step) of \(names.count)\(name)"
    }

    var body: some View {
        let marks = Self.marks(step: step, names: names)
        HStack(spacing: Space.base) {
            ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                if index > 0 { Hairline(.firm).frame(width: Space.gap) }
                Self.draw(mark, number: index + 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(step: step, names: names))
    }

    @ViewBuilder
    private static func draw(_ mark: Mark, number: Int) -> some View {
        switch mark {
        case .done:
            Image(systemName: "checkmark").font(Typography.micro).foregroundStyle(Palette.muted).ring()
        case .current(let name):
            HStack(spacing: Space.snug) {
                Text("\(number)").font(Typography.micro.tabular).foregroundStyle(Palette.surface)
                    .frame(width: Size.chip, height: Size.chip)
                    .background(Circle().fill(Palette.text))
                Text(name).font(Typography.label).foregroundStyle(Palette.text).lineLimit(1)
            }
        case .ahead(let number):
            Text("\(number)").font(Typography.micro.tabular).foregroundStyle(Palette.tertiary).ring()
        }
    }
}

private extension View {
    /// A step's `Size.chip` circle drawn as a 1 pt `Palette.borderStrong` ring round its mark.
    func ring() -> some View {
        frame(width: Size.chip, height: Size.chip)
            .overlay(Circle().strokeBorder(Palette.borderStrong, lineWidth: 1))
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
