import SwiftUI
import AiTermUI
import AiTermCore

/// What the overview's buttons do, handed in by `AppController.overviewActions(for:dismiss:)`; a
/// snapshot or a test hands in none.
struct OverviewActions {
    var approvePlan: @MainActor (Int) -> Void = { _ in }
    var pause: @MainActor () -> Void = {}
    var resume: @MainActor () -> Void = {}
    /// `confirming`: End Operation… asks first; a done operation's End Operation does not.
    var end: @MainActor (_ confirming: Bool) -> Void = { _ in }
    var giveItMore: @MainActor () -> Void = {}
    var openTask: @MainActor (UUID) -> Void = { _ in }
    var answerInWindow: @MainActor () -> Void = {}
    var decideLesson: @MainActor (String, LessonDecision, String?) -> Void = { _, _, _ in }
}

/// One of the overview footer's buttons, in the proposal's words.
enum OverviewButton: Hashable {
    case approvePlan, pause, resume, endConfirm, end, giveItMore
    var title: String {
        switch self {
        case .approvePlan: "Approve Plan"
        case .pause: "Pause"
        case .resume: "Resume"
        case .endConfirm: "End Operation…"
        case .end: "End Operation"
        case .giveItMore: "Give It More"
        }
    }

    /// What the button does with the overview the sheet shows: Approve Plan approves exactly the revision
    /// drawn, never the latest — a plan revised while the sheet is open needs its own approval.
    @MainActor func perform(_ overview: OperationOverview, _ actions: OverviewActions) {
        switch self {
        case .approvePlan: if let plan = overview.plan { actions.approvePlan(plan.revision) }
        case .pause: actions.pause()
        case .resume: actions.resume()
        case .endConfirm: actions.end(true)
        case .end: actions.end(false)
        case .giveItMore: actions.giveItMore()
        }
    }
}

/// The footer at each moment: plain buttons at the leading edge, and the primary on ⌘↩ — Approve Plan
/// while a plan waits, End Operation once it is done — after Close.
struct OverviewFooterButtons: Equatable {
    var leading: [OverviewButton]
    var primary: OverviewButton?

    init(_ footer: OperationOverview.Footer) {
        switch footer {
        case .planWaits: leading = [.endConfirm]; primary = .approvePlan
        case .working: leading = [.pause, .endConfirm]; primary = nil
        case .paused: leading = [.resume, .endConfirm]; primary = nil
        case .done: leading = [.giveItMore]; primary = .end
        }
    }
}

/// An operation's overview (spec §10.7): the operator and when it is done in the band; the plan on top
/// while one waits, in a `SettingsGroup` with each task's `+` or `~`; the board — Waiting on you with its count,
/// Working, Up next, Done — each a `SidebarHeading` over `Size.menuRow` rows; what it decided on its
/// own; the lessons to keep, edit or dismiss. Close is ⎋; the footer's other buttons are the moment's.
struct OperationOverviewSheet: View {
    let overview: OperationOverview
    let actions: OverviewActions
    @Environment(\.dismiss) private var dismiss
    /// The key column, fitted to `PLUTO-1088` in `Typography.mono`, so the titles start on one line —
    /// one-off, as `NewTaskSheet.ticketKeyWidth` is.
    private static let keyColumn: CGFloat = 72
    private var _editing = State<String?>(initialValue: nil)
    /// The lesson being edited, by key.
    private var editing: String? {
        get { _editing.wrappedValue }
        nonmutating set { _editing.wrappedValue = newValue }
    }
    private var _draft = State(initialValue: "")

    init(overview: OperationOverview, actions: OverviewActions) { self.overview = overview; self.actions = actions }

    var body: some View {
        let buttons = OverviewFooterButtons(overview.footer)
        SheetLayout(title: overview.title, height: Sheet.height) {
            SheetSubtitle(overview.subtitle)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                if let plan = overview.plan { planBox(plan) }
                ForEach(overview.groups) { board($0) }
                if let title = overview.decisionsTitle { notes(title, overview.decisions, lessons: false) }
                if let title = overview.lessonsTitle { notes(title, overview.lessons, lessons: true) }
            }
        } footer: {
            SheetFooter(secondary: "Close", primary: buttons.primary?.title, cancel: { dismiss.afterThisEvent() },
                        submit: { buttons.primary?.perform(overview, actions) }) {
                HStack(spacing: Space.base) {
                    ForEach(buttons.leading, id: \.self) { button in Button(button.title) { button.perform(overview, actions) } }
                }
            }
        }
    }

    private func planBox(_ plan: OperationOverview.Plan) -> some View {
        SettingsGroup(title: OperationOverview.Plan.title, help: plan.help) {
            VStack(alignment: .leading, spacing: Space.hairline) {
                ForEach(plan.rows) { row in
                    HStack(spacing: Space.base) {
                        // A diff's sign: added in its green, changed in the row's own ink.
                        Text(row.sign).font(Typography.monoCode).foregroundStyle(row.change == .added ? Palette.diffAdded : Palette.text)
                        key(row.key)
                        Text(row.title).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1)
                        Spacer(minLength: Space.base)
                        Text(row.detail).font(Typography.help).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    .frame(minHeight: Size.menuRow)
                }
            }
        }
    }

    private func board(_ group: OperationOverview.Group) -> some View {
        VStack(alignment: .leading, spacing: Space.hairline) {
            HStack(spacing: Space.base) {
                SidebarHeading(group.title)
                if let count = group.attention, count > 0 {
                    StatusCountChips(counts: [StatusCount(status: .needsInput, count: count)])
                }
            }
            .frame(height: Size.menuRow)
            ForEach(group.items) { item($0) }
        }
    }

    private func item(_ item: OperationOverview.Item) -> some View {
        HStack(spacing: Space.base) {
            StatusMark(status: Self.status(item.mark), size: Size.statusMark)
            key(item.key)
            if let avatars = item.avatars { AvatarGroupView(group: avatars) }
            Text(item.title).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Space.base)
            if !item.detail.isEmpty {
                Text(item.detail).font(Typography.help).foregroundStyle(Palette.muted).lineLimit(1)
            }
            if let link = item.link {
                Button(link.title) {
                    switch link {
                    case .openTask(let id): actions.openTask(id)
                    case .answerInWindow: actions.answerInWindow()
                    }
                }
                .buttonStyle(.link).font(Typography.caption)
            }
        }
        .frame(minHeight: Size.menuRow)
    }

    private func key(_ key: OperationOverview.Key) -> some View {
        let isTicket = if case .ticket = key { true } else { false }
        return Text(key.text).font(Typography.mono).foregroundStyle(isTicket ? Palette.link : Palette.muted)
            .lineLimit(1).frame(width: Self.keyColumn, alignment: .leading)
    }

    private func notes(_ title: String, _ notes: [OperationOverview.Note], lessons: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SidebarHeading(title).frame(height: Size.menuRow)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: Space.tight) {
                    VStack(alignment: .leading, spacing: Space.hairline) {
                        Text(note.text).font(Typography.caption).foregroundStyle(Palette.text).textSelection(.enabled)
                        Text(note.why).font(Typography.help).foregroundStyle(Palette.muted)
                    }
                    if lessons { lessonActions(note) }
                }
            }
        }
    }

    /// Keep, Edit and Dismiss; Edit turns the lesson into a field with Keep and Cancel.
    @ViewBuilder private func lessonActions(_ note: OperationOverview.Note) -> some View {
        if editing == note.id {
            Input(placeholder: note.text, text: _draft.projectedValue)
            HStack(spacing: Space.gap) {
                Button("Keep") { actions.decideLesson(note.key, .kept, _draft.wrappedValue); editing = nil }
                Button("Cancel") { editing = nil }
            }
            .buttonStyle(.link).font(Typography.caption)
        } else {
            HStack(spacing: Space.gap) {
                Button("Keep") { actions.decideLesson(note.key, .kept, nil) }
                Button("Edit") { _draft.wrappedValue = note.text; editing = note.id }
                Button("Dismiss") { actions.decideLesson(note.key, .dismissed, nil) }
            }
            .buttonStyle(.link).font(Typography.caption)
        }
    }

    private static func status(_ mark: OperationOverview.Mark) -> TaskStatus {
        switch mark {
        case .waiting: .needsInput
        case .working: .working
        case .upNext: .idle
        case .done: .done
        }
    }
}

/// The overview as the sidebar presents it: made again from the workspace whenever it changes, so a
/// task moves down the board while the sheet is open; an operation ended meanwhile closes it.
struct OperationOverviewHost: View {
    let runId: UUID
    let controller: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let run = controller.rows.runs[runId], run.state != .stopped {
            OperationOverviewSheet(overview: .make(run: run, state: controller.state, acting: controller.rows.acting),
                                   actions: controller.overviewActions(for: run, dismiss: { dismiss.afterThisEvent() }))
        } else {
            Color.clear.frame(width: Sheet.width, height: Size.control).onAppear { dismiss.afterThisEvent() }
        }
    }
}
