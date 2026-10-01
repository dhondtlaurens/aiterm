import Testing
@testable import AiTerm
import AiTermCore
import AiTermUI

@Suite struct CodeHostReviewCopyTests {
    @Test func eachHostNamesItsOwnRequests() {
        #expect(CodeHost.gitLab.reviewField == "Merge request (optional)")
        #expect(CodeHost.gitHub.reviewField == "Pull request (optional)")
        #expect(CodeHost.gitLab.reviewPlaceholder == "Search by !number, title or branch")
        #expect(CodeHost.gitHub.reviewPlaceholder == "Search by #number, title or branch")
        #expect(CodeHost.gitHub.reviewHint == "Select a pull request to fill in the name and branch.")
        #expect(CodeHost.gitHub.brand == Palette.github)
        #expect(CodeHost.gitLab.brand == Palette.gitlab)
    }
}
