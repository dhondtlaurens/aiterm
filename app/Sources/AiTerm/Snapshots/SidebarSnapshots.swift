import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// The sidebar's rows at every size, its footer and the Mac's rows in every mode, the marks, and
/// the sidebar's other states: a folded project, its banners, rows on their way out, a selected
/// header, and no project at all.
@MainActor
enum SidebarSnapshots {
    /// The sidebar and its footer, drawn first.
    static var rows: [Snapshot] {
        [
            // The real `SidebarView`, list and all; the images after it stack the list's rows by hand.
            Snapshot("sidebar-native.png", hostedOnly: true) {
                SidebarView(controller: Fixture().controller()).frame(width: 340, height: 600)
            },
            // The rows and the footer at each size, as tall as they are: a frame of a fixed height
            // clipped the `PROJECTS` heading off the top once the rows outgrew it.
            scaled("sidebar.png", .standard),
            // The two larger sizes, for judging the scale by eye.
            scaled("sidebar-large.png", .large),
            scaled("sidebar-extra-large.png", .extraLarge),
            // A task stacking two providers draws only its active tab's provider.
            Snapshot("sidebar-footer-agents.png") {
                let fixture = Fixture(), controller = fixture.controller()
                controller.focus.browse(.task(fixture.working.id))
                return footer(controller).frame(width: Size.sidebarWidth).background(Palette.sidebar).surface(.sidebar)
            },
            // The Mac's rows in every mode — its readings, and the backpack line's one colour — with
            // macOS's warnings on the last, for judging the inks by eye.
            Snapshot("sidebar-footer-mac.png") {
                let modes: [MacMode] = [.desk, .turningOn, .on, .needsYou(.lostHotspot), .needsYou(.lowBattery(level: 13)), .turningOff]
                return VStack(spacing: 0) {
                    ForEach(modes.indices, id: \.self) { index in
                        let mode = modes[index]
                        SidebarFooter(task: nil, rows: [], machine: machine(mode),
                                      mac: MacModePresentation.line(mode: mode, hotspot: "Laurens’s iPhone", wifi: "Office-WiFi"))
                    }
                }
                .frame(width: Size.sidebarWidth)
                .background(Palette.sidebar)
                .surface(.sidebar)
            },
        ]
    }

    /// Every round mark side by side at every size it is drawn at, plus one large row, so their
    /// optical balance can be judged against each other rather than one screen at a time.
    static var marks: Snapshot {
        Snapshot("marks.png") {
            VStack(alignment: .leading, spacing: Space.base) {
                ForEach([Size.vendorMark, Size.avatar, Size.control, 96], id: \.self) { size in
                    HStack(spacing: Space.base) {
                        ForEach([SessionAgent.claude, .codex, .grok, .pi, .shell], id: \.self) { VendorMark(agent: $0, size: size) }
                        IntegrationMark(service: .jira, size: size)
                        IntegrationMark(service: .gitlab, size: size)
                        IntegrationMark(service: .github, size: size)
                    }
                }
            }
            .padding(Space.inset)
            .background(Palette.sidebar)
        }
    }

    /// The sidebar's other states, each on a workspace changed for it alone.
    static var states: [Snapshot] {
        [
            // A folded project, with a task in every status, so the header's count chips have all
            // four to draw.
            Snapshot("sidebar-collapsed.png") {
                let fixture = Fixture(), controller = fixture.controller(), project = fixture.project
                let idle = TaskItem(id: UUID(), projectId: project.id, title: "Rename the settings pane", branch: "chore/settings",
                                    worktreePath: "/r/.worktrees/z", baseBranch: "main", jira: nil, agent: .claude, model: "opus",
                                    reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Snapshots.clock.now, windowId: nil)
                let done = TaskItem(id: UUID(), projectId: project.id, title: "Ship the usage footer", branch: "feat/usage-footer",
                                    worktreePath: "/r/.worktrees/w", baseBranch: "main", jira: nil, agent: .claude, model: "opus",
                                    reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Snapshots.clock.now, windowId: "w4")
                controller.workspace.mutate { $0.tasks = [fixture.working, fixture.other, idle, done] }
                controller.live.sessions += [Fixture.session("s6", "w4", done.id, "claude", "done", 0)].compactMap { $0 }
                controller.workspace.mutate { $0.updateProject(id: project.id) { $0.collapsed = true } }
                return VStack(alignment: .leading, spacing: Space.hairline) {
                    SidebarHeader(controller: controller)
                    SidebarView.rows(of: controller.rows.entries[0], in: controller.rows, controller: controller)
                    Spacer()
                }
                .padding(.horizontal, Space.inset)
                .frame(width: Size.sidebarWidth + 20, height: 76)
                .background(Palette.sidebar)
            },
            // Every banner the sidebar can raise, one of each tone: their text shares one leading edge.
            Snapshot("sidebar-banners.png") {
                VStack(spacing: 0) {
                    SidebarBanner(text: "Couldn’t save the workspace: the disk is full.", tone: .error,
                                  actions: [.init(title: "Retry Saving") {}])
                    SidebarBanner(text: "Branch feat/migrate-alert kept.", detail: "It has commits that aren’t on main.", tone: .error,
                                  actions: ["Keep Branch", "Delete Branch…", "Dismiss"].map { .init(title: $0) {} }, vertical: Space.base)
                    SidebarBanner(text: ItermConnection.refused("not allowed").banner?.text ?? "", tone: .warning, trailing: Space.block)
                    SidebarBanner(text: "Waiting for iTerm2…", tone: .info, trailing: Space.block)
                }
                .frame(width: Size.sidebarWidth + 20)
                .background(Palette.sidebar)
            },
            // Rows on their way out — removing, closing, and a removal that stopped short of the
            // row with its note — unselected, and selected, where the note yields its amber.
            removal("sidebar-removal.png", selecting: nil),
            removal("sidebar-removal-selected.png", selecting: \.other),
            // A project header on the arrow path, selected: open over its rows, and folded with its
            // count chips.
            selectedHeader("sidebar-header-selected.png", collapsed: false),
            selectedHeader("sidebar-header-selected-collapsed.png", collapsed: true),
            // No project yet: the block under `PROJECTS`, at ×1 and at the largest size.
            empty("sidebar-empty.png", .standard),
            empty("sidebar-empty-extra-large.png", .extraLarge),
        ]
    }

    /// The rows `SidebarView`'s list draws, from its own `rows(of:in:controller:)`, stacked:
    /// `ImageRenderer` never materialises a `List`.
    @ViewBuilder private static func listRows(_ controller: AppController) -> some View {
        let rows = controller.rows
        SidebarHeader(controller: controller)
        ForEach(rows.entries) { SidebarView.rows(of: $0, in: rows, controller: controller) }
    }

    /// The sidebar's footer for the selected row, its Mac at the desk.
    private static func footer(_ controller: AppController) -> SidebarFooter {
        SidebarFooter(task: controller.rows.usageRow(for: controller.focus.selection),
                      rows: SidebarModel.usageVendorRows(controller.live.usage, now: Snapshots.clock.now,
                                                         calendar: Snapshots.clock.calendar),
                      machine: machine(.desk))
    }

    /// The Mac's readings a snapshot draws, fixed: on mains at the desk; on battery in the bag, and
    /// throttled, swapping and near the cutoff once it needs you for the battery.
    private static func machine(_ mode: MacMode) -> [UsageLine] {
        switch mode {
        case .desk: [UsageLine(window: .cpu, percent: 23, warning: false), UsageLine(window: .ram, percent: 61, warning: false)]
        case .needsYou(.lowBattery(let level)):
            [UsageLine(window: .cpu, percent: 87, warning: true), UsageLine(window: .ram, percent: 78, warning: true),
             UsageLine(window: .battery, percent: level, warning: true)]
        default:
            [UsageLine(window: .cpu, percent: 23, warning: false), UsageLine(window: .ram, percent: 61, warning: false),
             UsageLine(window: .battery, percent: 64, warning: false)]
        }
    }

    /// The rows the list draws, inset as the List insets them, over the footer, which is a direct
    /// child of the real sidebar and adds that inset back itself — so the frame carries the inset
    /// on top of `sidebarWidth`.
    private static func scaled(_ file: String, _ scale: InterfaceScale) -> Snapshot {
        Snapshot(file) {
            let controller = Fixture().controller()
            return VStack(alignment: .leading, spacing: scale(Space.hairline)) {
                VStack(alignment: .leading, spacing: scale(Space.hairline)) { listRows(controller) }
                    .padding(.horizontal, scale(Space.inset))
                footer(controller)
            }
            .frame(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset))
            .fixedSize(horizontal: false, vertical: true)
            .background(Palette.sidebar)
            .interfaceScale(scale)
        }
    }

    /// The fixture's tasks mid-removal — two removing, one closing, and one whose removal kept its
    /// branch — with `selecting` selected, or the PI task. Only the task rows, as the list draws
    /// them: the project's header and terminal have nothing to say about a removal.
    private static func removal(_ file: String, selecting: KeyPath<Fixture, TaskItem>?) -> Snapshot {
        Snapshot(file) {
            let fixture = Fixture(), controller = fixture.controller()
            controller.seedSnapshotRemoval(.removing, of: fixture.working.id)
            controller.seedSnapshotRemoval(.removing, of: fixture.piTask.id)
            controller.seedSnapshotRemoval(.closing, of: fixture.grokTask.id)
            controller.seedSnapshotRemoval(.stopped(note: "Not removed: branch kept", worktreeRemoved: true), of: fixture.other.id)
            controller.report(.branchKept(fixture.other.branch, of: fixture.other.id, because: .notMerged(base: "develop")))
            if let selecting { controller.focus.browse(.task(fixture[keyPath: selecting].id)) }
            let rows = controller.rows
            return VStack(alignment: .leading, spacing: Space.hairline) {
                SidebarView.taskRows(of: rows.sections[0], in: rows, controller: controller)
            }
            .padding(.horizontal, Space.inset)
            .frame(width: Size.sidebarWidth + 20)
            .background(Palette.sidebar)
        }
    }

    private static func selectedHeader(_ file: String, collapsed: Bool) -> Snapshot {
        Snapshot(file) {
            let fixture = Fixture(), controller = fixture.controller()
            controller.focus.browse(.project(fixture.project.id))
            controller.workspace.mutate { $0.updateProject(id: fixture.project.id) { $0.collapsed = collapsed } }
            return VStack(alignment: .leading, spacing: Space.hairline) {
                SidebarView.rows(of: controller.rows.entries[0], in: controller.rows, controller: controller)
            }
            .padding(.horizontal, Space.inset).padding(.vertical, Space.tight)
            .frame(width: Size.sidebarWidth + 20)
            .background(Palette.sidebar)
        }
    }

    private static func empty(_ file: String, _ scale: InterfaceScale) -> Snapshot {
        Snapshot(file) {
            VStack(alignment: .leading, spacing: scale(Space.hairline)) {
                SidebarHeader(controller: Fixture.emptyController())
                SidebarEmptyState(canAdd: true, add: {})
                Spacer()
            }
            .padding(.horizontal, scale(Space.inset))
            .frame(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset), height: scale(200))
            .background(Palette.sidebar)
            .surface(.sidebar)
            .interfaceScale(scale)
        }
    }
}
#endif
