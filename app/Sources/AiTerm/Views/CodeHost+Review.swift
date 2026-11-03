import SwiftUI
import AiTermCore
import AiTermUI

/// What a review's host changes on screen: its mark, and what New Review calls its requests.
extension CodeHost {
    var brand: Brand { self == .gitHub ? Palette.github : Palette.gitlab }
    /// "merge request" or "pull request", for a sentence.
    var reviewNoun: String { self == .gitHub ? "pull request" : "merge request" }
    var reviewField: String { self == .gitHub ? "Pull request (optional)" : "Merge request (optional)" }
    var reviewPlaceholder: String { "Search by \(self == .gitHub ? "#" : "!")number, title or branch" }
    var reviewHint: String { "Select a \(reviewNoun) to fill in the name and branch." }
}

/// What a ticket's source changes on screen: its mark, and the ink of its lane chip — Jira's in the
/// link blue, a GitLab issue's label in GitLab's own colour, as a merge request's lane is.
extension JiraTicket {
    var brand: Brand { issueNumber == nil ? Palette.jira : Palette.gitlab }
    var laneInk: Color { issueNumber == nil ? Palette.link : Palette.gitlab.color }
}
