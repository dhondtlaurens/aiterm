import AppKit
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
    /// The native titlebar band, outside the scrolling list. AppKit supplies its height: it is
    /// window chrome, so the sidebar's interface scale must not change it.
    private static var titlebarHeight: CGFloat { NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height }

    /// Every view below reads the controller directly: with Observation each one re-renders for the
    /// properties it read, not for every change. So the toast, the sheet and the footer are views of
    /// their own — read here, any of them would re-run this body on every change to it. The list
    /// reads `controller.rows`, which changes only when a row does: not the workspace, whose sidebar
    /// frame and remembered choices no row draws.
    let controller: AppController

    /// One entry's rows, in the order the list draws them, after the Operator's: a divider, or a
    /// project's header and — open — its terminals, then its tasks. The snapshots stack the same rows, since
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

    /// The OPERATOR heading and, while a broadcast exists and its section is open, its group, as the list draws
    /// them above the projects: the Operator's row, the broadcast's lead, then the tasks it holds, the queued ones
    /// last. The heading is off the arrow path, as a divider is; the rest is on it, the Operator's row with an id of
    /// its own (`OperatorRow.id(of:)`), each task with its own.
    @ViewBuilder static func operatorRows(in rows: SidebarProjection, controller: AppController) -> some View {
        OperatorHeading(controller: controller).selectionDisabled()
        if let broadcast = rows.broadcast, !broadcast.folded {
            OperatorRowView(row: broadcast.operatorRow, controller: controller).tag(broadcast.operatorRow.id)
            ForEach(broadcast.tasks) { row in
                TaskRowView(row: row, task: rows.tasks[row.id], controller: controller).tag(row.id)
            }
        }
    }

    /// The PROJECTS heading and, unless they are folded into OPERATOR while the broadcast's section is open, every
    /// entry's rows: what the list draws under the Operator's, and the snapshots stack.
    @ViewBuilder static func projectRows(in rows: SidebarProjection, controller: AppController) -> some View {
        SidebarHeader(controller: controller).selectionDisabled()
        if !rows.projectsFolded {
            if !rows.hasProjects {
                SidebarEmptyState(controller: controller).selectionDisabled()
            }
            ForEach(rows.entries) { Self.rows(of: $0, in: rows, controller: controller) }
        }
    }

    var body: some View {
        let scale = controller.preferences.interfaceSize.scale
        let rows = controller.rows
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.titlebarHeight).accessibilityHidden(true)
            SidebarBanners(controller: controller)
            ScrollViewReader { scroller in
                List(selection: selection) {
                    Self.operatorRows(in: rows, controller: controller)
                    .listRowSeparator(.hidden)
                    Self.projectRows(in: rows, controller: controller)
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
                .background(SidebarScrollFollower(focus: controller.focus) { selection in
                    // A row in the folded section opens it first, folding the other.
                    controller.reveal(selection)
                    // The main run loop runs this block on the main thread, where the proxy lives.
                    nonisolated(unsafe) let proxy = scroller
                    RunLoop.main.perform { MainActor.assumeIsolated { proxy.scrollTo(selection.id) } }
                })
            }
            // List's native scroll-edge extension must not paint a row or its selection into the
            // reserved titlebar band, even while rubber-banding or scrolling a selected row up.
            .clipped()
            SidebarFooterHost(controller: controller)
        }
        .ignoresSafeArea(.container, edges: .top)
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
                                                    hotspot: backpack.network, wifi: backpack.currentNetwork,
                                                    until: backpack.state.until),
                      toggleMac: { controller.toggleBackpack() },
                      openMacSettings: { controller.presentSettings(tab: .integrations) })
    }
}

/// Scrolls the list to a row selected away from it — Focus View, a notification bringing its window
/// forward — which can sit below the fold, or in the folded section. No anchor, so a row already in view does
/// not move and a click or an arrow key scrolls nothing. Next turn: scrolled in this one, the list stopped a
/// row short of the last one. Its own view, so the selection moving re-runs this and not the list.
struct SidebarScrollFollower: View {
    let focus: RowFocus
    /// Shows a row, a turn later.
    let scrollTo: (RowSelection) -> Void

    var body: some View {
        Color.clear.onChange(of: focus.selection) { _, selection in
            if let selection { scrollTo(selection) }
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

/// What sits above the list: a failed save, a failed operation, the Operator's refused wake line, and the
/// helper's connection state. The first three, and iTerm2 refusing the connection, are `Notice`s; the grey
/// line while AiTerm connects is not a request, and stays a line of muted text.
struct SidebarBanners: View {
    let controller: AppController

    var body: some View {
        if let message = controller.persistenceError {
            SidebarBanner {
                Notice(title: message, description: nil) {
                    Button("Retry Saving") { controller.workspace.flush() }
                }
            }
        }
        if let issue = controller.issue {
            IssueBanner(issue: issue, fix: controller.notices.fixSession,
                        perform: { action in Task { await controller.perform(action) } },
                        cancelFix: { controller.notices.cancelFix() }, dismiss: { controller.dismissIssue() })
        }
        if let wake = controller.operatorController.wakeNotice {
            OperatorWakeBanner(notice: wake, open: { controller.openOperatorWindow(of: wake.run) },
                               fix: { controller.presentAgentSettings(for: .claude) })
        }
        if let banner = controller.helper.itermConnection.banner {
            SidebarConnectionBanner(banner: banner, status: controller.helper.itermConnection.status)
        }
    }
}

/// The helper's connection state: grey while it connects, which waits on nothing of yours; a
/// `Notice` while iTerm2 refuses the connection, which waits on you — the card's status its title,
/// what to do its description.
struct SidebarConnectionBanner: View {
    let banner: DaemonBanner
    /// `ItermConnection.status`, which the banner's text opens with.
    let status: String

    /// The refusal's title and description: the status as a sentence, then the rest of the banner's text.
    static func notice(_ text: String, status: String) -> (title: String, description: String?) {
        let title = status + "."
        guard text.hasPrefix(title + " ") else { return (text, nil) }
        return (title, String(text.dropFirst(title.count + 1)))
    }

    var body: some View {
        switch banner.tone {
        case .warning:
            let notice = Self.notice(banner.text, status: status)
            SidebarBanner(trailing: Space.block) { Notice(title: notice.title, description: notice.description) }
        case .info:
            SidebarBanner(trailing: Space.block) { SidebarBannerText(text: banner.text) }
        }
    }
}

/// The Operator's wake line refused (`OperatorWakeNotice`): what waits on it and why, with Open the Operator
/// and Fix in Settings as its links. The Operator runs on Claude Code, whose card Fix in Settings is for.
struct OperatorWakeBanner: View {
    let notice: OperatorWakeNotice
    let open: () -> Void
    let fix: () -> Void

    var body: some View {
        SidebarBanner(vertical: Space.base) {
            Notice(title: OperatorWakeNotice.title, description: notice.description) {
                Button("Open the Operator", action: open)
                Button("Fix in Settings", action: fix)
            }
        }
    }
}

/// A failed operation above the list, and the Find a Fix it offers (`BannerFixPresentation`), as one
/// `Notice`: the issue's title and reason, its ways out as links — then, once a fix is asked for, the
/// busy line or the proposal under the issue, with Apply and Cancel, and Applying… with the banner held.
struct IssueBanner: View {
    let issue: OperationIssue
    /// The Fix offered for the issue, if any; its state is the one thing here it observes.
    let fix: FixSession?
    let perform: (OperationIssue.Action) -> Void
    let cancelFix: () -> Void
    let dismiss: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let shown = BannerFixPresentation(issue: issue, state: fix?.state, fixer: fix?.fixer)
        SidebarBanner(vertical: Space.base) {
            switch shown.content {
            case .text(let title, let detail, let help):
                Notice(title: title, description: detail, help: help) { links(shown.links) }
            case .busy(let line):
                Notice(title: issue.title, description: issue.reason, help: issue.detail) {
                    FixBusyLine(text: line, compact: true)
                } actions: { links(shown.links) }
            case .proposal(let agent, let proposal):
                Notice(title: issue.title, description: issue.reason, help: issue.detail) {
                    FixProposalBlock(agent: agent, proposal: proposal, compact: true)
                } actions: { links(shown.links) }
            }
        }
    }

    @ViewBuilder private func links(_ links: [BannerFixPresentation.Link]) -> some View {
        ForEach(links.indices, id: \.self) { index in
            let link = links[index]
            switch link {
            case .action(let action): Button(link.title) { perform(action) }
            case .fix(_, let isEnabled, let help):
                Button { fix?.start() } label: { FixOfferLabel(scale: scale) }.disabled(!isEnabled).help(help)
            case .tryAgain(let help): Button(link.title) { fix?.tryAgain() }.help(help)
            case .apply(let help): Button(link.title) { fix?.apply() }.help(help)
            case .cancel(let isEnabled): Button(link.title, action: cancelFix).disabled(!isEnabled)
            case .dismiss: Button(link.title, action: dismiss)
            }
        }
    }
}

/// Find a Fix, led by the Operator's mark — its agent's, Claude's — at `Size.inlineMark`, where Fix
/// with AI had `sparkles`: the fix runs as the Operator. `scale` is the surface's: the sidebar's, or
/// ×1 in a sheet.
struct FixOfferLabel: View {
    var scale: InterfaceScale = .standard

    var body: some View {
        HStack(spacing: scale(Space.tight)) {
            VendorMark(agent: .claude, size: scale(Size.inlineMark))
            Text(FixOffer.title)
        }
    }
}

/// What stands above the list: its content's text starts where the `PROJECTS` heading's does, the
/// list's inset plus `Space.base`, as the sidebar footer's marks do below.
///
/// Only the leading edge is shared. `trailing` and `vertical` (×1 tokens, scaled here) keep each
/// banner's own margins as they were — a failed operation stands a little taller, the helper's
/// state wraps a little sooner — until someone decides the three should be one.
struct SidebarBanner<Content: View>: View {
    var trailing: CGFloat = Space.base
    var vertical: CGFloat = Space.snug
    @ViewBuilder let content: Content
    @Environment(\.interfaceScale) private var scale

    init(trailing: CGFloat = Space.base, vertical: CGFloat = Space.snug, @ViewBuilder content: () -> Content) {
        self.trailing = trailing; self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, scale(Space.inset) + scale(Space.base))
            .padding(.trailing, scale(trailing))
            .padding(.vertical, scale(vertical))
    }
}

/// The grey line while AiTerm connects: in `Typography.help` and `Palette.muted`. Not a `Notice`: it
/// waits on nothing of yours.
struct SidebarBannerText: View {
    let text: String

    var body: some View {
        Text(text).font(Typography.help).foregroundStyle(Palette.muted).textSelection(.enabled)
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
                        case .broadcast(let run): controller.rename(run: run, to: name)
                        }
                    })
                case .settings(let jira, let gitLab, let gitHub, let tab, let agent):
                    SettingsView(jiraConfig: jira, gitLabConfig: gitLab, gitHubConfig: gitHub,
                                 harnessModel: controller.agents.harnessSettingsModel(),
                                 agents: controller.agents,
                                 messaging: controller.messaging,
                                 itermConnection: { controller.helper.itermConnection },
                                 checkIterm: controller.helper.checkIterm,
                                 preferences: controller.preferences,
                                 setMatchItermBackground: { controller.helper.setMatchItermBackground($0) },
                                 setInterfaceSize: { controller.tiling.setInterfaceSize($0) },
                                 initialTab: tab,
                                 initialAgent: agent,
                                 backpack: controller.backpack)
                case .backpack(let model): BackpackSheet(model: model)
                case .archive(let model): ArchiveSheet(model: model)
                case .newBroadcast(let model): NewBroadcastSheet(model: model)
                case .broadcastBoard(let id): BroadcastBoardHost(runId: id, controller: controller)
                case .shelvedBroadcast(let id): BroadcastBoardHost(runId: id, source: .shelved, controller: controller)
            }
        }
        .interfaceScale(.standard)
        // A sheet presented from the sidebar would otherwise inherit its `.sidebar` ground.
        .surface(.sheet)
    }
}
