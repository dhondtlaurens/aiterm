import Foundation
import Testing
@testable import AiTermCore

@Suite struct GitHubQueryTests {
    @Test func startQueryGainsIsPrAndIsOpenOnlyWhenMissing() throws {
        #expect(try GitHubQuery.start("review-requested:@me").text == "is:pr is:open review-requested:@me")
        #expect(try GitHubQuery.start("is:pr author:@me").text == "is:open is:pr author:@me")
        #expect(try GitHubQuery.start("author:@me is:merged").text == "is:pr author:@me is:merged")
        #expect(try GitHubQuery.start("author:@me is:closed").text == "is:pr author:@me is:closed")
        #expect(try GitHubQuery.start("is:open author:@me").text == "is:pr is:open author:@me")
        #expect(try GitHubQuery.start("state:closed author:@me").text == "is:pr state:closed author:@me")
    }

    @Test func doneQueryGainsOnlyIsPr() throws {
        #expect(try GitHubQuery.done("review:approved").text == "is:pr review:approved")
        #expect(try GitHubQuery.done("is:pr is:merged").text == "is:pr is:merged")
    }

    @Test func threadTokensAreSplitOffAndTheRestKeptAsWritten() throws {
        let query = try GitHubQuery.start(#"author:@me -threads:resolved label:"needs review" threads:waiting-on-me"#)
        #expect(query.text == #"is:pr is:open author:@me label:"needs review""#)
        #expect(query.threads == [ThreadFilter(kind: .resolved, negated: true), ThreadFilter(kind: .waitingOnMe)])
    }

    @Test func issuesAreRefused() {
        #expect(throws: QueryRefusal(token: "is:issue", message: "A GitHub trigger lists pull requests; remove is:issue.")) {
            try GitHubQuery.start("is:issue author:@me")
        }
        #expect(throws: QueryRefusal(token: "threads:all", message: "threads takes waiting-on-me or resolved.")) {
            try GitHubQuery.done("threads:all")
        }
    }
}
