import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A task branch's request, read from the project's remote with the saved connections: an open or
/// merged one is taken, a closed one is not, and a host that is not connected is never asked.
@Suite struct BranchRequestReaderTests {
    let gitLab = GitLabConfig(hostURL: URL(string: "https://gitlab.example.net")!, token: "gl")
    let remote = "git@gitlab.example.net:web/shop.git"

    private func mergeRequest(_ iid: Int, state: String) -> String {
        #"{"iid":\#(iid),"title":"Fix \#(iid)","source_branch":"feat/x","target_branch":"main","web_url":"https://gitlab.example.net/web/shop/-/merge_requests/\#(iid)","state":"\#(state)"}"#
    }

    /// GitLab answers `opened` for the open list and `all` for the branch's history.
    private func gitLabStub(open: [String], all: [String]) -> StubSession {
        StubSession { request in
            let query = request.url?.query ?? ""
            let list = query.contains("state=opened") ? open : all
            // Only the first page of the history holds anything.
            let body = query.contains("state=all") && !query.contains("page=1") ? "[]" : "[" + list.joined(separator: ",") + "]"
            return (200, Data(body.utf8))
        }
    }

    @Test func anOpenRequestIsTaken() async throws {
        let stub = gitLabStub(open: [mergeRequest(7, state: "opened")], all: [])
        let reader = BranchRequestReader(gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await reader.request(remoteUrl: remote, branch: "feat/x")
                == MergeRequestRef(iid: 7, title: "Fix 7", url: "https://gitlab.example.net/web/shop/-/merge_requests/7"))
        #expect(stub.requests.count == 1)
        #expect(stub.lastRequest?.url?.query?.contains("source_branch=feat/x") == true)
    }

    @Test func aMergedRequestIsTaken() async throws {
        let stub = gitLabStub(open: [], all: [mergeRequest(8, state: "merged")])
        let reader = BranchRequestReader(gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await reader.request(remoteUrl: remote, branch: "feat/x")?.iid == 8)
    }

    /// A request closed without merging was given up: the branch has none to show.
    @Test func aClosedRequestIsNot() async throws {
        let stub = gitLabStub(open: [], all: [mergeRequest(9, state: "closed")])
        let reader = BranchRequestReader(gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await reader.request(remoteUrl: remote, branch: "feat/x") == nil)
    }

    @Test func aBranchWithoutARequestHasNone() async throws {
        let stub = gitLabStub(open: [], all: [])
        let reader = BranchRequestReader(gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await reader.request(remoteUrl: remote, branch: "feat/x") == nil)
    }

    /// No connection, another GitLab host, or no remote at all: nothing is asked, and there is no request.
    @Test func aHostThatIsNotConnectedIsNotAsked() async throws {
        let stub = gitLabStub(open: [mergeRequest(7, state: "opened")], all: [])
        let unconnected = BranchRequestReader(gitLab: nil, gitHub: nil, session: stub.session)
        #expect(try await unconnected.request(remoteUrl: remote, branch: "feat/x") == nil)
        #expect(try await unconnected.request(remoteUrl: "https://github.com/octocat/hello.git", branch: "feat/x") == nil)
        let connected = BranchRequestReader(gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await connected.request(remoteUrl: "git@gitlab.com:web/shop.git", branch: "feat/x") == nil)
        #expect(try await connected.request(remoteUrl: nil, branch: "feat/x") == nil)
        #expect(stub.requests.isEmpty)
    }

    @Test func aFailedReadThrows() async {
        let stub = StubSession { _ in (500, Data("{}".utf8)) }
        let reader = BranchRequestReader(gitLab: gitLab, gitHub: nil, session: stub.session)
        await #expect(throws: (any Error).self) { try await reader.request(remoteUrl: remote, branch: "feat/x") }
    }
}
