import Foundation
import Testing
@testable import AiTermCore

/// GitLab search-bar queries against the GraphQL arguments of GitLab CE 19.5.3's merge request lists.
@Suite struct GitLabQueryTests {
    struct Row: Sendable, CustomTestStringConvertible {
        var query: String, role: GitLabQuery.Role, arguments: [String: JSONValue]
        var threads: [ThreadFilter] = [], projects: [String] = []
        var testDescription: String { query }
    }

    static let rows: [Row] = [
        Row(query: "reviewer:@me review-state:unreviewed draft:no", role: .reviewer,
            arguments: ["reviewStates": ["UNREVIEWED"], "draft": false]),
        Row(query: "assignee:@me review-state:requested_changes,reviewed", role: .assignee,
            arguments: ["reviewStates": ["REQUESTED_CHANGES", "REVIEWED"]]),
        Row(query: "assignee:@me threads:waiting-on-me", role: .assignee, arguments: [:],
            threads: [ThreadFilter(kind: .waitingOnMe)]),
        Row(query: "assignee:@me review-state:approved draft:no threads:resolved", role: .assignee,
            arguments: ["reviewStates": ["APPROVED"], "draft": false], threads: [ThreadFilter(kind: .resolved)]),
        Row(query: "assignee:@me reviewer:any -reviewer:@me", role: .assignee,
            arguments: ["reviewerWildcardId": "ANY", "not": ["reviewerUsername": "alex"]]),
        Row(query: "reviewer:@me -assignee:@me", role: .reviewer, arguments: ["not": ["assigneeUsernames": ["alex"]]]),
        Row(query: #"author:@me label:"needs review" target-branch:main project:shop/webshop"#, role: .author,
            arguments: ["labels": ["needs review"], "targetBranches": ["main"]], projects: ["shop/webshop"]),
    ]

    @Test(arguments: rows) func startQueryParsesIntoItsRootAndArguments(_ row: Row) throws {
        let query = try GitLabQuery.start(row.query)
        #expect(query.role == row.role)
        #expect(query.threads == row.threads && query.projects == row.projects && query.state == "opened")
        let request = query.request(user: "alex", project: row.projects.first)
        var filters = request.variables
        for key in ["first", "state", "projectPath"] { filters[key] = nil }
        #expect(filters == row.arguments)
        #expect(request.query.contains("currentUser{list:\(row.role.root)("))
        #expect(request.variables["projectPath"] == row.projects.first.map(JSONValue.string))
    }

    @Test func everyUserValueTravelsAsAVariable() throws {
        let query = try GitLabQuery.start(#"author:@me label:"needs review" -assignee:sam milestone:"Sprint 9""#)
        let request = query.request(user: "alex", project: "shop/webshop", cursor: "abc")
        for value in ["needs review", "sam", "Sprint 9", "shop/webshop", "abc", "alex"] { #expect(!request.query.contains(value)) }
        #expect(request.variables["after"] == "abc" && request.variables["first"] == 100)
        #expect(request.variables["milestoneTitle"] == "Sprint 9")
        #expect(request.query.hasPrefix("query($first:Int!,$after:String,$state:MergeRequestState,$projectPath:String,"))
        #expect(request.query.contains("$not:MergeRequestsResolverNegatedParams") && request.query.contains("not:$not"))
    }

    @Test func doneQueryWithoutARoleReadsTheProjectsMergeRequests() throws {
        let query = try GitLabQuery.done("review-state:approved")
        #expect(query.role == nil && query.state == "all")
        let request = query.request(user: "alex", project: "shop/webshop", iids: [7], nodes: "iid")
        #expect(request.query.contains("project(fullPath:$fullPath){list:mergeRequests("))
        #expect(request.query.contains("$fullPath:ID!") && request.query.contains("nodes{iid}"))
        #expect(request.variables["fullPath"] == "shop/webshop" && request.variables["iids"] == ["7"])
        #expect(request.variables["projectPath"] == nil && request.variables["state"] == "all")
    }

    @Test func stateDefaultsPerEntryPointAndAQueryCanStateItsOwn() throws {
        #expect(try GitLabQuery.start("author:@me").state == "opened")
        #expect(try GitLabQuery.done("author:@me").state == "all")
        #expect(try GitLabQuery.done("author:@me").role == .author)
        #expect(try GitLabQuery.start("author:@me state:merged").state == "merged")
    }

    @Test func repeatingTheRolesOwnTokenIsFine() throws {
        #expect(try GitLabQuery.start("reviewer:@me reviewer:@me").role == .reviewer)
    }

    @Test func usernamesLoseTheirAtSign() throws {
        let request = try GitLabQuery.start("reviewer:@me author:@sam approved-by:@me").request(user: "alex", project: nil)
        #expect(request.variables["authorUsername"] == "sam" && request.variables["approvedBy"] == ["alex"])
    }

    struct Refused: Sendable, CustomTestStringConvertible {
        var text: String, token: String, message: String
        init(_ text: String, _ token: String, _ message: String) { self.text = text; self.token = token; self.message = message }
        var testDescription: String { text }
    }

    @Test(arguments: [
        Refused("label:agent", "", "Name yourself in one role: author:@me, assignee:@me or reviewer:@me."),
        Refused("author:@me reviewer:@me", "reviewer:@me", "Name yourself in one role: keep one of author:@me and reviewer:@me."),
        Refused("assignee:@me colour:red", "colour:red", "Unknown filter colour:red."),
        Refused("reviewer:@me review-state:done", "review-state:done",
                "review-state takes unreviewed, review_started, reviewed, requested_changes, approved or unapproved."),
        Refused("reviewer:@me -draft:no", "-draft:no", "Write draft:yes or draft:no rather than -draft:no."),
        Refused("assignee:@me author:alex,sam", "author:alex,sam", "author takes one value, not a list."),
        Refused(#"author:@me label:"needs review"#, #"label:"needs review"#, #"Close the quote in label:"needs review."#),
        Refused("reviewer:@me reviewer:sam", "reviewer:sam", "reviewer:sam cannot be combined with reviewer:@me."),
        Refused("assignee:@me -assignee:any", "-assignee:any", "-assignee:any cannot be combined with assignee:@me."),
        Refused("author:@me -project:shop/webshop", "-project:shop/webshop", "GitLab cannot exclude with -project:shop/webshop; remove the -."),
        Refused("author:@me draft:maybe", "draft:maybe", "draft takes yes or no."),
        Refused("author:@me threads:mine", "threads:mine", "threads takes waiting-on-me or resolved."),
        Refused("author:@me state:open", "state:open", "state takes opened, merged, closed or all."),
        Refused("author:@me milestone:a milestone:b", "milestone:b", "milestone appears twice with different values; keep one."),
        Refused("author:@me label:", "label:", "label: needs a value."),
    ]) func startQueryRefusals(_ row: Refused) {
        #expect(throws: QueryRefusal(token: row.token, message: row.message)) { try GitLabQuery.start(row.text) }
    }

    @Test func doneQueryRefusesTwoRolesButNotNone() throws {
        #expect(throws: QueryRefusal(token: "assignee:@me", message: "Name yourself in one role: keep one of author:@me and assignee:@me.")) {
            try GitLabQuery.done("author:@me assignee:@me")
        }
        #expect(try GitLabQuery.done("-reviewer:@me label:agent").role == nil)
    }

    @Test func negatedWildcardsSwapAndNegatedNamesGoIntoNot() throws {
        let request = try GitLabQuery.done("-reviewer:none -assignee:any -label:wip -target-branch:main -approved-by:sam -review-state:approved")
            .request(user: "alex", project: "shop/webshop")
        #expect(request.variables["reviewerWildcardId"] == "ANY" && request.variables["assigneeWildcardId"] == "NONE")
        #expect(request.variables["not"] == ["labels": ["wip"], "targetBranches": ["main"], "approvedBy": ["sam"], "reviewStates": ["APPROVED"]])
    }

    @Test func projectListsOnePathPerCommaWithoutRepeats() throws {
        #expect(try GitLabQuery.start("author:@me project:shop/webshop,shop/api project:Shop/Webshop").projects == ["shop/webshop", "shop/api"])
    }
}
