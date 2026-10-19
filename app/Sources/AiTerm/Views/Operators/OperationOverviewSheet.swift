import SwiftUI
import AiTermUI
import AiTermCore

/// What the overview's buttons do, handed in by `AppController.overviewActions(for:dismiss:)`; a
/// snapshot or a test hands in none.
struct OverviewActions {
    var pause: @MainActor () -> Void = {}
    var resume: @MainActor () -> Void = {}
    /// `confirming`: End Operation… asks first; a done operation's End Operation does not.
    var end: @MainActor (_ confirming: Bool) -> Void = { _ in }
    var giveItMore: @MainActor () -> Void = {}
    var openTask: @MainActor (UUID) -> Void = { _ in }
    var answerInWindow: @MainActor () -> Void = {}
}

/// One of the overview footer's buttons, in the proposal's words.
enum OverviewButton: Hashable {
    case pause, resume, endConfirm, end, giveItMore
    var title: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .endConfirm: "End Operation…"
        case .end: "End Operation"
        case .giveItMore: "Give It More"
        }
    }

    /// What the button does.
    @MainActor func perform(_ overview: OperationOverview, _ actions: OverviewActions) {
        switch self {
        case .pause: actions.pause()
        case .resume: actions.resume()
        case .endConfirm: actions.end(true)
        case .end: actions.end(false)
        case .giveItMore: actions.giveItMore()
        }
    }
}

/// The footer at each moment: plain buttons at the leading edge, and the primary on ⌘↩ — End Operation
/// once it is done — after Close.
struct OverviewFooterButtons: Equatable {
    var leading: [OverviewButton]
    var primary: OverviewButton?

    init(_ footer: OperationOverview.Footer) {
        switch footer {
        case .working: leading = [.pause, .endConfirm]; primary = nil
        case .paused: leading = [.resume, .endConfirm]; primary = nil
        case .done: leading = [.giveItMore]; primary = .end
        }
    }
}

/// An operation's overview (spec §10.7): the operator and when it is done in the band; the board — Waiting on you with its count,
/// Working, Up next, Done — each a `SidebarHeading` over `Size.menuRow` rows; what it decided on its
/// own. Close is ⎋; the footer's other buttons are the moment's.
struct OperationOverviewSheet: View {
    let overview: OperationOverview
    let actions: OverviewActions
    @Environment(\.dismiss) private var dismiss
    /// The key column, fitted to `PLUTO-1088` in `Typography.mono`, so the titles start on one line —
    /// one-off, as `NewTaskSheet.ticketKeyWidth` is.
    private static let keyColumn: CGFloat = 72

    init(overview: OperationOverview, actions: OverviewActions) { self.overview = overview; self.actions = actions }

    var body: some View {
        let buttons = OverviewFooterButtons(overview.footer)
        SheetLayout(title: overview.title, height: Sheet.height) {
            SheetSubtitle(overview.subtitle)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                ForEach(overview.groups) { board($0) }
                if let title = overview.decisionsTitle { notes(title, overview.decisions) }
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

    private func notes(_ title: String, _ notes: [OperationOverview.Note]) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SidebarHeading(title).frame(height: Size.menuRow)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text(note.text).font(Typography.caption).foregroundStyle(Palette.text).textSelection(.enabled)
                    Text(note.why).font(Typography.help).foregroundStyle(Palette.muted)
                }
            }
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
