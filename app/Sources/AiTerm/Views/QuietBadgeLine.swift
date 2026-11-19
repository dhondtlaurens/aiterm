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
    /// The mark wears the corner check: the ticket done, the request merged.
    var checked = false
    var accessibilityLabel: String? = nil
    var markInk: Badge.MarkInk = .own
    var action: (() -> Void)? = nil

    /// The same value, its mark checked or not.
    func checked(_ checked: Bool) -> Self { var value = self; value.checked = checked; return value }
}

/// Ticket, then request, including the GitLab pair's one shared mark, which wears either's check. The surrounding
/// row owns its gap and editor badge. Passive surfaces fix each badge's size as before.
struct QuietBadgeLine: View {
    var ticket: QuietBadgeValue?
    var request: QuietBadgeValue? = nil
    var sharesMark = false
    var fixed = false
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        if sharesMark, let ticket, let request {
            if ticket.label == nil, request.label == nil {
                badge(QuietBadgeValue(icon: ticket.icon,
                                      help: "\(ticket.help ?? "") · \(request.help ?? "")",
                                      suffix: request.suffix, checked: ticket.checked || request.checked,
                                      accessibilityLabel: request.accessibilityLabel,
                                      markInk: ticket.markInk, action: request.action))
            } else {
                HStack(spacing: scale(Space.snug)) {
                    // The mark is on the ticket's badge, so it wears the request's check too.
                    badge(ticket.checked(ticket.checked || request.checked))
                    if request.label != nil || request.suffix != nil {
                        badge(QuietBadgeValue(label: request.label, help: request.help, suffix: request.suffix,
                                              accessibilityLabel: request.accessibilityLabel, markInk: request.markInk,
                                              action: request.action))
                    }
                }
            }
        } else {
            if let ticket { badge(ticket) }
            if let request { badge(request) }
        }
    }

    @ViewBuilder private func badge(_ value: QuietBadgeValue) -> some View {
        let badge = Badge(value.label, icon: value.icon, help: value.help, suffix: value.suffix, checked: value.checked,
                          style: .quiet, markInk: value.markInk, accessibilityLabel: value.accessibilityLabel,
                          action: value.action)
        if fixed { badge.fixedSize() } else { badge }
    }
}
