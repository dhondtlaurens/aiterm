import SwiftUI
import AiTermUI
import AiTermCore

/// Set by the snapshot harness when it draws with `ImageRenderer`, which cannot materialise a
/// `ScrollView`'s contents: `SheetLayout` then lays its content out flat and clipped instead.
private struct SnapshotRenderingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}

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
    let onBackgroundTap: (() -> Void)?
    @Environment(\.snapshotRendering) private var isSnapshot
    let navigation: Navigation
    let content: Content
    let footer: Footer

    init(title: String, height: CGFloat, onBackgroundTap: (() -> Void)? = nil,
         @ViewBuilder navigation: () -> Navigation,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.height = height
        self.onBackgroundTap = onBackgroundTap
        self.navigation = navigation()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.block) {
                Text(title).font(Typography.title).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.middle).help(title)
                navigation.frame(height: Size.control)
            }
            .padding(.horizontal, Space.margin).padding(.top, Space.section).padding(.bottom, Space.block)
            Hairline()
            Group {
                // ImageRenderer cannot materialize ScrollView contents.
                if isSnapshot {
                    paddedContent.frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
                } else {
                    ScrollView { paddedContent }
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
        content.frame(maxWidth: .infinity, alignment: .topLeading).padding(Space.margin)
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
struct SheetPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        // The label sits on the accent fill, and says so: the keycaps read it.
        Button(action: action) { HStack(spacing: Space.base) { Text(title); Kbd("⌘", "↩") }.surface(.accent) }
            .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
            .disabled(!enabled)
    }
}

/// The foot of every sheet: Cancel — or Back, whatever `secondary` says — and the primary action
/// at the trailing edge, with optional `status` text before them.
///
/// ⎋ is a hidden button of its own, not Cancel's key: an open list closes first — a button's key
/// equivalent would beat the field's own ⎋, and in every other app that list is a window of its own,
/// so closing the whole sheet is not what the key means there — and *clicking* Cancel still cancels.
/// `closeList` closes one and says whether there was one to close; a sheet with no lists needs
/// nothing, and ⎋ is Cancel. `cancel` guards itself when it must, as Back does while a create runs.
///
/// A pattern, not a primitive: it encodes where *this app* puts a sheet's actions.
struct SheetFooter<Status: View>: View {
    let secondary: String
    let primary: String
    let canCancel: Bool
    let canSubmit: Bool
    let closeList: () -> Bool
    let cancel: () -> Void
    let submit: () -> Void
    let status: Status

    init(secondary: String = "Cancel", primary: String, canCancel: Bool = true, canSubmit: Bool = true,
         closeList: @escaping () -> Bool = { false }, cancel: @escaping () -> Void, submit: @escaping () -> Void,
         @ViewBuilder status: () -> Status = { EmptyView() }) {
        self.secondary = secondary; self.primary = primary; self.canCancel = canCancel; self.canSubmit = canSubmit
        self.closeList = closeList; self.cancel = cancel; self.submit = submit; self.status = status()
    }

    var body: some View {
        HStack(spacing: Space.base) {
            status
            Spacer(minLength: Space.base)
            Button(secondary, action: cancel).disabled(!canCancel)
            SheetPrimaryButton(title: primary, enabled: canSubmit, action: submit)
        }
        .controlSize(.large)
        .overlay { Button("Close") { if !closeList() { cancel() } }.keyboardShortcut(.cancelAction).hidden() }
    }
}

/// The footer New Task and New Review share: the last failure, why no agent can run, and a
/// `SheetFooter` — Back, or Cancel on the first step, and Continue or the create button.
///
/// A failure shows its reason, never the head of git's output: that is the command line and git's
/// narration, and three lines of it used to be all there was room for. The reason is git's failure
/// lines as one sentence (`GitError.sentence`), or any other error's own, as the banner has it —
/// short by construction, so it is never cut; git's whole output is the tooltip.
struct CreationFooter: View {
    let step: Int
    let error: CreationFailure?
    let availableAgents: Set<AgentKind>
    let createLabel: String
    let creating: Bool
    let canAdvance: Bool
    let closeList: () -> Bool
    let back: () -> Void
    let advance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            if let error {
                Text(error.reason).font(Typography.caption).foregroundStyle(Palette.amber).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).help(error.detail ?? error.reason)
            }
            if step == 3, availableAgents.isEmpty, let note = AgentStep.missingAgentNote(available: availableAgents) {
                Text(note).font(Typography.caption).foregroundStyle(Palette.amber)
            }
            SheetFooter(secondary: step == 1 ? "Cancel" : "Back", primary: step == 3 ? createLabel : "Continue",
                        canCancel: !creating, canSubmit: canAdvance, closeList: closeList, cancel: back, submit: advance)
        }
    }
}

/// 1 Task —— 2 Agent —— 3 Prompt, spread across the full width of the header: the connectors
/// stretch, so the three steps sit at the left, middle and right rather than bunching up.
struct StepBar: View {
    let step: Int
    /// New Task's first step names a ticket; New Review's names a branch. Everything else about
    /// the bar is identical, so the names are the only thing that varies.
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
            HStack(spacing: Space.snug) {
                VendorMark(agent: agent.session, size: Size.vendorMark)
                Text(agent.displayName).font(on ? Typography.bodyEmphasis : Typography.body)
            }
            .foregroundStyle(on ? Palette.text : Palette.muted)
        }
    }
}

/// The exact command the task will run, on one line, with the whole thing in the tooltip.
struct CommandBlock: View {
    let caption: String
    let command: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(caption).font(Typography.help).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
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
