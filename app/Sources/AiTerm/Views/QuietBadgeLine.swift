import SwiftUI
import AiTermUI

/// One quiet badge's existing words, artwork and optional link. Callers choose their
/// surface's mark: a sidebar row inks it with its words (`markInk: .label`); sheet and question
/// ticket marks deliberately remain their own.
struct QuietBadgeValue {
    var label: String?
    var icon: IconSource?
    var help: String?
    var suffix: Badge.Suffix? = nil
    /// What the mark wears on its corner: the ticket done, the request approved and resolved, or merged.
    var corner: SettledMark.Kind? = nil
    var accessibilityLabel: String? = nil
    var markInk: Badge.MarkInk = .own
    var action: (() -> Void)? = nil
}

/// Ticket, then request, including the GitLab pair's one shared mark, which wears the request's corner over the
/// ticket's. The surrounding row owns its gap and editor badge. Passive surfaces fix each badge's size as before.
struct QuietBadgeLine: View {
    var ticket: QuietBadgeValue?
    var request: QuietBadgeValue? = nil
    var sharesMark = false
    var fixed = false
    @Environment(\.interfaceScale) private var scale

    /// The badges the line draws, in order, and whether they are the shared mark's pair, set `Space.snug` apart
    /// rather than at the row's gap.
    struct Parts {
        var badges: [QuietBadgeValue]
        var pair = false
    }

    /// What the line draws for these values. On the shared GitLab mark the request's corner wins, and a request that
    /// has nothing of its own left to draw (no number, no thread count) keeps its words on the one badge there is.
    static func parts(ticket: QuietBadgeValue?, request: QuietBadgeValue?, sharesMark: Bool) -> Parts {
        guard sharesMark, let ticket, let request else { return Parts(badges: [ticket, request].compactMap { $0 }) }
        var mark = ticket
        mark.corner = request.corner ?? ticket.corner
        if ticket.label == nil, request.label == nil {
            mark.help = "\(ticket.help ?? "") · \(request.help ?? "")"
            mark.suffix = request.suffix
            mark.accessibilityLabel = request.accessibilityLabel
            mark.action = request.action
            return Parts(badges: [mark])
        }
        guard request.label != nil || request.suffix != nil else {
            mark.help = "\(ticket.help ?? "") · \(request.help ?? "")"
            mark.accessibilityLabel = "\(ticket.accessibilityLabel ?? ticket.label ?? ticket.help ?? ""), "
                + (request.accessibilityLabel ?? request.help ?? "")
            return Parts(badges: [mark])
        }
        // The mark is on the ticket's badge, so the request's badge draws its words without one.
        var words = request
        words.icon = nil
        words.corner = nil
        return Parts(badges: [mark, words], pair: true)
    }

    var body: some View {
        let parts = Self.parts(ticket: ticket, request: request, sharesMark: sharesMark)
        if parts.pair {
            HStack(spacing: scale(Space.snug)) {
                ForEach(parts.badges.indices, id: \.self) { badge(parts.badges[$0]) }
            }
        } else {
            ForEach(parts.badges.indices, id: \.self) { badge(parts.badges[$0]) }
        }
    }

    @ViewBuilder private func badge(_ value: QuietBadgeValue) -> some View {
        let badge = Badge(value.label, icon: value.icon, help: value.help, suffix: value.suffix, corner: value.corner,
                          style: .quiet, markInk: value.markInk, accessibilityLabel: value.accessibilityLabel,
                          action: value.action)
        if fixed { badge.fixedSize() } else { badge }
    }
}
