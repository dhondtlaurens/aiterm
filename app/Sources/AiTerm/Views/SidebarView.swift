import SwiftUI
import AiTermUI
import AiTermCore

/// The instant and calendar the usage footer reads its reset times against. Unset, the footer uses
/// the wall clock and the user's calendar; the snapshot harness pins both so the labels it draws
/// do not move with the time of day, the weekday or the machine's time zone.
struct FooterClock {
    var now: Date
    var calendar: Calendar
}

private struct FooterClockKey: EnvironmentKey { static let defaultValue: FooterClock? = nil }

extension EnvironmentValues {
    var footerClock: FooterClock? {
        get { self[FooterClockKey.self] }
        set { self[FooterClockKey.self] = newValue }
    }
}

struct SidebarView: View {
    /// Every view below reads the controller directly: with Observation each one re-renders for the
    /// properties it read, not for every change. So the toast, the sheet and the footer are views of
    /// their own — read here, any of them would re-run this body on every change to it. The list
    /// reads `controller.rows`, which changes only when a row does: not the workspace, whose sidebar
    /// frame and remembered choices no row draws.
    let controller: AppController

    /// One entry's rows, in the order the list draws them: a divider, or a project's header and —
    /// open — its terminals, then its tasks. The snapshots stack the same rows, since
    /// `ImageRenderer` cannot draw a `List`, so they cannot show another order.
    @ViewBuilder static func rows(of entry: SidebarEntry, in rows: SidebarProjection, controller: AppController) -> some View {
        switch entry {
        case .divider(let divider):
            DividerRow(entry: divider, controller: controller).selectionDisabled()
        case .project(let section):
            // On the arrow path, as a Finder outline's folders are; a divider is not.
            ProjectHeaderRow(section: section, controller: controller).tag(section.project.id)
            if !section.collapsed {
                ForEach(section.terminals) { row in
                    TerminalRowView(row: row, terminal: rows.terminals[row.id], project: section.project, controller: controller)
                        .tag(row.id)
                }
                taskRows(of: section, in: rows, controller: controller)
            }
        }
    }

    /// A project's task rows, as the list draws them under its terminals: what the removal
    /// snapshots stack on their own.
    @ViewBuilder static func taskRows(of section: ProjectSection, in rows: SidebarProjection, controller: AppController) -> some View {
        ForEach(section.tasks) { row in
            TaskRowView(row: row, task: rows.tasks[row.id], controller: controller)
                .tag(row.id)
        }
    }

    var body: some View {
        let scale = controller.preferences.interfaceSize.scale
        let rows = controller.rows
        VStack(spacing: 0) {
            SidebarBanners(controller: controller)
            ScrollViewReader { scroller in
                List(selection: selection) {
                    SidebarHeader(controller: controller).selectionDisabled()
                    if !rows.hasProjects {
                        SidebarEmptyState(controller: controller).selectionDisabled().listRowSeparator(.hidden)
                    }
                    ForEach(rows.entries) { Self.rows(of: $0, in: rows, controller: controller) }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
                // Selection is drawn by the row so it can stay blue while iTerm2 is key. The table
                // still owns keyboard navigation; only its focus-dependent gray highlight is hidden.
                .scrollContentBackground(.hidden)
                .background(NativeRowHighlight.off)
                // A plain ↩: ⌘↩ is the sheets' commit key, not the list's.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    controller.activateSelection()
                    return .handled
                }
                // On the list, not a menu command: a menu's key equivalent would beat a text field's
                // own ⌘⌫ — delete to the line's start — in every sheet and field of the app. ⌫ arrives
                // as U+007F: `KeyEquivalent.delete` is U+0008, which a key press never matches.
                .onKeyPress("\u{7F}", phases: .down) { press in
                    guard press.modifiers == .command else { return .ignored }
                    // The question is asked a turn later, never inside SwiftUI's key handler, where
                    // an alert run modally came up without its "Delete local branch" checkbox
                    // (`Prompter`).
                    Task { await controller.removeSelection() }
                    return .handled
                }
                .background(SidebarScrollFollower(focus: controller.focus) { id in
                    // The main run loop runs this block on the main thread, where the proxy lives.
                    nonisolated(unsafe) let proxy = scroller
                    RunLoop.main.perform { MainActor.assumeIsolated { proxy.scrollTo(id) } }
                })
            }
            SidebarFooterHost(controller: controller)
        }
        .overlay(alignment: .bottom) { SidebarToast(controller: controller) }
        .frame(minWidth: scale(Size.sidebarMinWidth))
        .background(Palette.sidebar)
        .tint(Palette.accent)
        .interfaceScale(scale)
        // Declared, not defaulted: a component outside a row — the header, a divider, the footer —
        // otherwise read `.sheet`, the default for everything away from the sidebar.
        .surface(.sidebar)
        .background { SidebarSheetPresenter(controller: controller) }
    }

    /// Written by the list's own arrow keys, so a change peeks at the row's window. A click then
    /// commits through the row's tap.
    private var selection: Binding<UUID?> {
        Binding(get: { controller.focus.selection?.id }, set: { controller.focus.peek(id: $0) })
    }
}

/// The sidebar's foot, SYSTEM over USAGE. The vendor rows are worked out here, from the usage,
/// whether Claude's status line is AiTerm's, and the minute; the selected row's context row and the
/// Mac's rows in ``SelectedRowSidebarFooter``, which alone reads the tabs, the context fills, the
/// selection, the Mac's readings and Backpack Mode — so a session event or a 5 s sample redraws the
/// footer without working out the vendor rows again.
struct SidebarFooterHost: View {
    let controller: AppController
    @Environment(\.footerClock) private var footerClock

    var body: some View {
        // The rows depend on the clock — a window that has reset is dropped, and a reset time
        // gains its weekday across midnight — so they are recomputed on the minute, not only
        // when the usage changes.
        TimelineView(.everyMinute) { context in
            SelectedRowSidebarFooter(controller: controller,
                                     vendors: SidebarModel.usageVendorRows(controller.live.usage, now: footerClock?.now ?? context.date,
                                                                           calendar: footerClock?.calendar ?? .current,
                                                                           claudeStatusLineInstalled: controller.agents.claudeStatusLineInstalled))
        }
    }
}

/// ``SidebarFooter`` with the selected row's context row and the Mac's rows over the vendor rows it
/// is handed. A click on the Mac's rows is ⌘B; a right-click opens Settings › Integrations.
struct SelectedRowSidebarFooter: View {
    let controller: AppController
    let vendors: [UsageVendorRow]

    var body: some View {
        let backpack = controller.backpack
        SidebarFooter(task: controller.rows.usageRow(for: controller.focus.selection), rows: vendors,
                      machine: controller.machine.lines,
                      mac: MacModePresentation.line(mode: MacMode(state: backpack.state, transition: backpack.transition),
                                                    hotspot: backpack.network, wifi: backpack.currentNetwork),
                      toggleMac: { controller.toggleBackpack() },
                      openMacSettings: { controller.presentSettings(tab: .integrations) })
    }
}

/// Scrolls the list to a row selected away from it — Focus View, a notification bringing its window
/// forward — which can sit below the fold. No anchor, so a row already in view does not move and a
/// click or an arrow key scrolls nothing. Next turn: scrolled in this one, the list stopped a row
/// short of the last one. Its own view, so the selection moving re-runs this and not the list.
struct SidebarScrollFollower: View {
    let focus: RowFocus
    /// Scrolls to a row, a turn later.
    let scrollTo: (UUID) -> Void

    var body: some View {
        Color.clear.onChange(of: focus.selection?.id) { _, id in
            if let id { scrollTo(id) }
        }
    }
}

/// The completion toast over the sidebar's foot. Its own view, so a toast coming and going redraws
/// this and not the list.
struct SidebarToast: View {
    let controller: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        // The animation is scoped to the toast: it appears in the same turn a removed row
        // disappears, and on the whole sidebar it animated that removal too.
        ZStack {
            if let toast = controller.toastState.toast {
                ToastView(toast: toast)
                    .padding(.bottom, scale(Space.block))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.toastState.toast)
    }
}

/// Presents `controller.sheet`. Its own view, reading nothing else, so a change to the list does
/// not rebuild the open sheet's root — nor a sheet opening or closing re-run the list's body.
struct SidebarSheetPresenter: View {
    @Bindable var controller: AppController

    var body: some View {
        Color.clear.sheet(item: $controller.sheet) { SidebarSheet(kind: $0, controller: controller) }
    }
}

/// What sits above the list: a failed save, a failed operation, and the helper's connection state.
struct SidebarBanners: View {
    let controller: AppController

    var body: some View {
        if let message = controller.persistenceError {
            SidebarBanner(text: message, tone: .error, actions: [.init(title: "Retry Saving") { controller.workspace.flush() }])
        }
        if let issue = controller.issue {
            IssueBanner(issue: issue, fix: controller.notices.fixSession,
                        perform: { action in Task { await controller.perform(action) } },
                        cancelFix: { controller.notices.cancelFix() }, dismiss: { controller.dismissIssue() })
        }
        if let banner = controller.helper.itermConnection.banner {
            // Amber, like "Usage disconnected": a warning waits on the person, not on a retry.
            SidebarBanner(text: banner.text, tone: banner.tone == .warning ? .warning : .info, trailing: Space.block)
        }
    }
}

/// A failed operation above the list, and the Fix it offers (`BannerFixPresentation`): the
/// issue's sentence and its ways out, then — once a Fix is asked for — the agent's line, its
/// proposal with Apply and Cancel, and Applying… with the banner held, where the sentence was.
struct IssueBanner: View {
    let issue: OperationIssue
    /// The Fix offered for the issue, if any; its state is the one thing here it observes.
    let fix: FixSession?
    let perform: (OperationIssue.Action) -> Void
    let cancelFix: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let shown = BannerFixPresentation(issue: issue, state: fix?.state, fixer: fix?.fixer)
        let actions = shown.links.map(action)
        switch shown.content {
        case .text(let title, let detail, let help):
            SidebarBanner(text: title, detail: detail, help: help, tone: .error, actions: actions, vertical: Space.base)
        case .busy(let line):
            SidebarBanner(tone: .error, actions: actions, vertical: Space.base) { FixBusyLine(text: line, compact: true) }
        case .proposal(let agent, let proposal):
            SidebarBanner(tone: .error, actions: actions, vertical: Space.base) {
                FixProposalBlock(agent: agent, proposal: proposal, compact: true)
            }
        }
    }

    private func action(_ link: BannerFixPresentation.Link) -> SidebarBannerAction {
        switch link {
        case .action(let action): .init(title: link.title) { perform(action) }
        case .fix(_, let isEnabled, let help): .init(title: link.title, isEnabled: isEnabled, help: help) { fix?.start() }
        case .tryAgain(let help): .init(title: link.title, help: help) { fix?.tryAgain() }
        case .apply(let help): .init(title: link.title, help: help) { fix?.apply() }
        case .cancel(let isEnabled): .init(title: link.title, isEnabled: isEnabled, perform: cancelFix)
        case .dismiss: .init(title: link.title, perform: dismiss)
        }
    }
}

/// What inks a banner's sentence: `.error` `Palette.text`, `.warning` `Palette.amber`, `.info` `Palette.muted`.
enum SidebarBannerTone { case error, warning, info }

/// A banner's link: its title, what it does, and — greyed — why it cannot.
struct SidebarBannerAction {
    let title: String
    var isEnabled = true
    var help: String? = nil
    let perform: () -> Void
}

/// One line — or a few — above the list, and the links that answer it. Its text starts where the
/// `PROJECTS` heading's does, the list's inset plus `Space.base`, as the sidebar footer's marks do below.
/// `detail` follows `text` in `Palette.muted`: what happened, then why; `help` is the tooltip, git's
/// whole output where there is one. Built with `content` instead, it draws that in the text's place —
/// a Fix's line or its proposal — with the same margins and links.
///
/// Only the leading edge is shared. `trailing` and `vertical` (×1 tokens, scaled here) keep each
/// banner's own margins as they were — a failed operation stands a little taller, the helper's
/// state wraps a little sooner — until someone decides the three should be one.
struct SidebarBanner<Content: View>: View {
    typealias Action = SidebarBannerAction
    typealias Tone = SidebarBannerTone

    let tone: Tone
    var actions: [Action] = []
    var trailing: CGFloat = Space.base
    var vertical: CGFloat = Space.snug
    @ViewBuilder let content: Content
    @Environment(\.interfaceScale) private var scale

    init(tone: Tone, actions: [Action] = [], trailing: CGFloat = Space.base, vertical: CGFloat = Space.snug,
         @ViewBuilder content: () -> Content) {
        self.tone = tone; self.actions = actions; self.trailing = trailing; self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            content
            if !actions.isEmpty {
                HStack(spacing: scale(Space.gap)) {
                    ForEach(actions.indices, id: \.self) { index in
                        let action = actions[index]
                        Button(action.title, action: action.perform).disabled(!action.isEnabled).help(action.help ?? "")
                    }
                }
                .buttonStyle(.link).font(Typography.help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, scale(Space.inset) + scale(Space.base))
        .padding(.trailing, scale(trailing))
        .padding(.vertical, scale(vertical))
    }
}

extension SidebarBanner where Content == SidebarBannerText {
    init(text: String, detail: String? = nil, help: String? = nil, tone: Tone, actions: [Action] = [],
         trailing: CGFloat = Space.base, vertical: CGFloat = Space.snug) {
        self.init(tone: tone, actions: actions, trailing: trailing, vertical: vertical) {
            SidebarBannerText(text: text, detail: detail, help: help, tone: tone)
        }
    }
}

/// A banner's sentence: `text` in its tone's ink, `detail` after it in `Palette.muted`.
struct SidebarBannerText: View {
    let text: String
    let detail: String?
    let help: String?
    let tone: SidebarBannerTone

    private var ink: Color {
        switch tone {
        case .error: Palette.text
        case .warning: Palette.amber
        case .info: Palette.muted
        }
    }

    var body: some View {
        // Interpolated, so neither part is read as Markdown: a branch name can hold a `*` or `_`.
        Group {
            if let detail { Text("\(text) \(Text(detail).foregroundStyle(Palette.muted))") } else { Text(text) }
        }
        .font(Typography.help).foregroundStyle(ink).textSelection(.enabled)
        .help(help ?? "")
    }
}

/// The sheet each `SheetKind` presents, wired to the controller that asked for it.
struct SidebarSheet: View {
    let kind: AppController.SheetKind
    let controller: AppController

    var body: some View {
        // Sheets keep Apple's sizes: their pop-up and push buttons are AppKit bezels that stop at
        // 28 pt, so a scaled sheet's fields would outgrow them.
        Group {
            switch kind {
                case .jiraProjects(let project):
                    JiraProjectSheet(projectName: project.name, linked: project.jiraProjects,
                                     canSubmit: controller.canChangeWorkspace,
                                     loadProjects: controller.loadJiraProjects,
                                     submit: { controller.setJiraProjects($0, on: project) })
                case .newTask(let model): NewTaskSheet(model: model)
                case .newReview(let model): NewReviewSheet(model: model)
                case .newTerminal(let project, let name, let branch): NameSheet.newTerminal(project: project, suggestedName: name, branch: branch, canCreate: controller.canChangeWorkspace, createTerminal: { controller.newTerminal(project: project, name: $0) })
                case .newDivider:
                    NameSheet.newDivider(canSubmit: controller.canChangeWorkspace, submit: { controller.addDivider(name: $0) })
                case .rename(let target):
                    NameSheet.rename(target, canSubmit: controller.canChangeWorkspace, submit: { name in
                        switch target {
                        case .divider(let divider): controller.rename(divider: divider, to: name)
                        case .task(let task): controller.rename(task: task, to: name)
                        case .terminal(let terminal): controller.rename(terminal: terminal, to: name)
                        }
                    })
                case .settings(let jira, let gitLab, let gitHub, let tab):
                    SettingsView(jiraConfig: jira, gitLabConfig: gitLab, gitHubConfig: gitHub,
                                 harnessModel: controller.agents.harnessSettingsModel(),
                                 agents: controller.agents,
                                 itermConnection: { controller.helper.itermConnection },
                                 checkIterm: controller.helper.checkIterm,
                                 preferences: controller.preferences,
                                 setMatchItermBackground: { controller.helper.setMatchItermBackground($0) },
                                 setInterfaceSize: { controller.tiling.setInterfaceSize($0) },
                                 initialTab: tab,
                                 backpack: controller.backpack)
                case .backpack(let model): BackpackSheet(model: model)
                case .archive(let model): ArchiveSheet(model: model)
                case .operatorEditor(let model): OperatorSheet(model: model)
                case .newOperation(let model): NewOperationSheet(model: model)
            }
        }
        .interfaceScale(.standard)
        // A sheet presented from the sidebar would otherwise inherit its `.sidebar` ground.
        .surface(.sheet)
    }
}
