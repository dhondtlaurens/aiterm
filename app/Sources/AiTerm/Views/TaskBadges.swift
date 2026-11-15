import SwiftUI
import AiTermCore
import AiTermUI

struct TaskBadges: View {
    let ticket: String?
    let ticketSummary: String?
    let mr: String?
    let mrHost: CodeHost?
    let mrTitle: String?
    var ticketIsGitLabIssue = false

    var body: some View {
        let host = mrHost ?? .gitLab
        QuietBadgeLine(ticket: ticket.map { QuietBadgeValue(label: $0, icon: .brand(ticketIsGitLabIssue ? Palette.gitlab : Palette.jira), help: ticketSummary) },
                       request: mr.map { QuietBadgeValue(label: $0, icon: .brand(host.brand), help: mrTitle) },
                       sharesMark: ticketIsGitLabIssue && host == .gitLab,
                       fixed: true)
    }

}
