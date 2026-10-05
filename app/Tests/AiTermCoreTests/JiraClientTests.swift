import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct JiraClientTests {
    let config = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "me@example.com", token: "tok")
    let issue: [String: Any] = ["key": "WEB-5447", "fields": ["summary": "Add graceful SIGTERM", "status": ["name": "In Progress"], "issuetype": ["name": "Task"],
                                                            "description": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Drain tasks."]]]]]]]

    @Test func testMyOpenIssuesParsesAndAuthenticates() async throws {
        let page = try JSONSerialization.data(withJSONObject: ["issues": [issue]])
        let stub = StubSession { _ in (200, page) }
        let tickets = try await JiraClient(config: config, session: stub.session).myOpenIssues()
        #expect(tickets == [JiraTicket(key: "WEB-5447", summary: "Add graceful SIGTERM", description: "Drain tasks.", issueType: "Task", status: "In Progress", url: "https://example.atlassian.net/browse/WEB-5447")])
        let req = stub.lastRequest!
        #expect(req.url?.path == "/rest/api/3/search/jql")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me@example.com:tok".utf8).base64EncodedString())
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        #expect(body?["jql"] as? String == "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC")
    }

    @Test func testSearchByKeyAndByText() async throws {
        let stub = keyStub()
        let client = JiraClient(config: config, session: stub.session)
        _ = try await client.search(text: "shop-1713")
        #expect(pickerQueries(stub) == ["SHOP-1713"])
        #expect(stub.requests.compactMap { pickerValue("currentJQL", of: $0) } == ["ORDER BY updated DESC"])
        #expect(jqls(stub) == [#"key = "SHOP-1713""#])
        _ = try await client.search(text: "sigterm \"worker\"")
        #expect(jql(stub) == "text ~ \"sigterm \\\"worker\\\"\" AND statusCategory != Done ORDER BY updated DESC")
    }

    @Test func partialKeySearchReturnsExactAndLongerKeysWithFullDetails() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/rest/api/3/issue/picker" {
                #expect(pickerValue("query", of: request) == "WEB-55")
                return (200, Data(#"{"sections":[{"id":"cs","issues":[{"key":"WEB-5595"},{"key":"WEB-55"},{"key":"WEB-155"}]},{"id":"hs","issues":[{"key":"WEB-55"}]}]}"#.utf8))
            }
            if jqlBody(request) == #"key = "WEB-55""# {
                return (200, Data(#"{"issues":[{"key":"WEB-55","fields":{"summary":"Exact","description":"Details","status":{"name":"Done"}}}]}"#.utf8))
            }
            #expect(jqlBody(request) == #"key in ("WEB-5595") AND statusCategory != Done"#)
            return (200, Data(#"{"issues":[{"key":"WEB-5595","fields":{"summary":"Longer"}}]}"#.utf8))
        }
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "  web-55\n")
        #expect(tickets.map(\.key) == ["WEB-55", "WEB-5595"])
        #expect(tickets.first?.status == "Done")
        #expect(tickets.first?.summary == "Exact")
        #expect(tickets.first?.description == "Details")
    }

    /// The picker suggests only some keys, and never one the issue has moved from; `key =` finds
    /// both, so a typed full key always reaches its ticket.
    @Test func aFullKeyFindsItsTicketEvenWhenMovedOrNotSuggested() async throws {
        let stub = keyStub(search: { $0 == #"project in ("SHOP") AND key = "SUP-12""# ? ["SHOP-40"] : [] })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "sup-12", projects: [app])
        #expect(tickets.map(\.key) == ["SHOP-40"])
    }

    @Test func aKeyJiraCannotResolveStillListsLongerKeys() async throws {
        let stub = keyStub(picker: ["SHOP-1": ["SHOP-10", "SHOP-11"]], search: { $0 == #"key = "SHOP-1""# ? nil : ["SHOP-10", "SHOP-11"] })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-1")
        #expect(tickets.map(\.key) == ["SHOP-10", "SHOP-11"])
    }

    /// Jira fails the whole `key in (…)` when one key in it no longer resolves.
    @Test func aSuggestedKeyThatNoLongerResolvesDropsOnlyItself() async throws {
        let stub = keyStub(picker: ["SHOP-1": ["SHOP-10", "SHOP-11"]], search: { jql in
            jql.hasPrefix("key in") || jql.hasPrefix(#"key = "SHOP-11""#) ? nil : jql.hasPrefix(#"key = "SHOP-10""#) ? ["SHOP-10"] : []
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-1")
        #expect(tickets.map(\.key) == ["SHOP-10"])
        #expect(Set(jqls(stub)) == [#"key = "SHOP-1""#, #"key in ("SHOP-10", "SHOP-11") AND statusCategory != Done"#,
                                    #"key = "SHOP-10" AND statusCategory != Done"#, #"key = "SHOP-11" AND statusCategory != Done"#])
    }

    /// Exact numbers first, then the picker's most recently updated matches taken from each project
    /// in turn, then tickets whose text mentions the number.
    @Test func numericSearchRanksExactKeysThenEachProjectsSuggestionsThenText() async throws {
        let scope = #"project in ("SHOP", "PAY")"#
        let stub = keyStub(picker: ["SHOP-2": ["SHOP-20", "SHOP-2", "SHOP-200"], "PAY-2": ["PAY-2", "PAY-21"]],
                           history: ["SHOP-2": ["SUP-2"]], search: { jql in
            switch jql {
            case scope + #" AND key = "SHOP-2""#: ["SHOP-2"]
            case scope + #" AND key = "PAY-2""#: ["PAY-2"]
            case scope + #" AND key in ("SHOP-20", "PAY-21", "SHOP-200") AND statusCategory != Done"#: ["SHOP-200", "SHOP-20", "PAY-21"]
            case scope + #" AND text ~ "2" AND statusCategory != Done ORDER BY updated DESC"#: ["SHOP-7", "SHOP-2"]
            default: nil
            }
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "2", projects: [app, ops])
        #expect(tickets.map(\.key) == ["SHOP-2", "PAY-2", "SHOP-20", "PAY-21", "SHOP-200", "SHOP-7"])
        #expect(Set(pickerQueries(stub)) == ["SHOP-2", "PAY-2"])
        #expect(Set(stub.requests.compactMap { pickerValue("currentJQL", of: $0) }) == [scope + " ORDER BY updated DESC"])
    }

    /// With no project to put it in, a number is no key; it may still be in a title.
    @Test func aNumberWithoutLinkedProjectsIsATextSearch() async throws {
        let stub = keyStub()
        _ = try await JiraClient(config: config, session: stub.session).search(text: "404")
        #expect(pickerQueries(stub).isEmpty)
        #expect(jqls(stub) == [#"text ~ "404" AND statusCategory != Done ORDER BY updated DESC"#])
    }

    /// Jira's default key format needs a project key of two characters or more.
    @Test func aOneLetterProjectKeyIsATextSearch() async throws {
        let stub = keyStub()
        _ = try await JiraClient(config: config, session: stub.session).search(text: "B-52")
        #expect(pickerQueries(stub).isEmpty)
        #expect(jqls(stub) == [#"text ~ "B\\-52" AND statusCategory != Done ORDER BY updated DESC"#])
    }

    @Test func leadingZerosAreDroppedFromKeysButNotFromText() async throws {
        let stub = keyStub()
        let client = JiraClient(config: config, session: stub.session)
        _ = try await client.search(text: "shop-007")
        #expect(pickerQueries(stub) == ["SHOP-7"])
        #expect(jqls(stub) == [#"key = "SHOP-7""#])
        let numbers = keyStub(picker: ["SHOP-7": ["SHOP-70"]])
        _ = try await JiraClient(config: config, session: numbers.session).search(text: "07", projects: [app])
        #expect(pickerQueries(numbers) == ["SHOP-7"])
        #expect(jqls(numbers).contains(#"project in ("SHOP") AND text ~ "07" AND statusCategory != Done ORDER BY updated DESC"#))
        #expect(jqls(numbers).contains(#"project in ("SHOP") AND key in ("SHOP-70") AND statusCategory != Done"#))
    }

    /// `text ~` goes through Lucene, where these characters are operators; a summary pasted as
    /// the query — `[Frontend] …`, `C++`, `fix: x` — made Jira answer 400 or search for something
    /// else. Each takes a backslash, which the JQL string literal needs doubled.
    @Test func textSearchEscapesLuceneOperators() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)
        let tail = " AND statusCategory != Done ORDER BY updated DESC"
        _ = try await client.search(text: "[Frontend] C++ fix: x")
        #expect(jql(stub) == #"text ~ "\\[Frontend\\] C\\+\\+ fix\\: x""# + tail)
        _ = try await client.search(text: #"a-b && c || !d (e) {f} ^g ~h *i ?j k/l"#)
        #expect(jql(stub) == #"text ~ "a\\-b \\&\\& c \\|\\| \\!d \\(e\\) \\{f\\} \\^g \\~h \\*i \\?j k\\/l""# + tail)
        _ = try await client.search(text: #"back\slash "quoted""#)
        #expect(jql(stub) == #"text ~ "back\\\\slash \"quoted\"""# + tail)
    }

    @Test func testIssueSearchesAreScopedToEveryLinkedProject() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[],\"sections\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)
        let projects = [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: config.siteURL),
                        JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: config.siteURL)]

        _ = try await client.myOpenIssues(projects: projects)
        #expect(jql(stub) == "project in (\"SHOP\", \"PAY\") AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC")
        let keys = keyStub()
        _ = try await JiraClient(config: config, session: keys.session).search(text: "pay-8773", projects: projects)
        #expect(pickerQueries(keys) == ["PAY-8773"])
        #expect(keys.requests.compactMap { pickerValue("currentJQL", of: $0) } == [#"project in ("SHOP", "PAY") ORDER BY updated DESC"#])
        #expect(jqls(keys) == [#"project in ("SHOP", "PAY") AND key = "PAY-8773""#])
        _ = try await client.search(text: "worker", projects: Array(projects.prefix(1)))
        #expect(jql(stub) == "project in (\"SHOP\") AND text ~ \"worker\" AND statusCategory != Done ORDER BY updated DESC")
        _ = try await client.search(text: "worker", projects: [])
        #expect(jql(stub) == "text ~ \"worker\" AND statusCategory != Done ORDER BY updated DESC",
                "no linked project searches every project")
    }

    @Test func testALinkedProjectKeyIsEscapedInsideItsJQLString() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let odd = JiraProjectRef(id: "1", key: #"A"B\C"#, name: "Odd", siteURL: config.siteURL)

        _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: [odd])

        #expect(jql(stub)?.hasPrefix(#"project in ("A\"B\\C") AND "#) == true)
    }

    /// Every linked project is checked against the configured site, not only the first.
    @Test func testIssueSearchRejectsASecondProjectLinkedToAnotherJiraSite() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let projects = [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: config.siteURL),
                        JiraProjectRef(id: "10002", key: "OLD", name: "Old", siteURL: URL(string: "https://old.atlassian.net")!)]

        await #expect(throws: JiraError.projectSiteMismatch(linked: URL(string: "https://old.atlassian.net")!,
                                                            configured: config.siteURL)) {
            _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: projects)
        }
        #expect(stub.lastRequest == nil)
    }

    @Test func testIssueSearchRejectsAProjectLinkedToAnotherJiraSite() async throws {
        let project = try JSONDecoder().decode(
            JiraProjectRef.self,
            from: Data(#"{"id":"10001","key":"SHOP","name":"Storefront","siteURL":"https://alice:secret@old.atlassian.net:443/"}"#.utf8)
        )
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)

        do {
            _ = try await client.myOpenIssues(projects: [project])
            Issue.record("Expected a Jira site mismatch")
        } catch {
            #expect(error.localizedDescription.contains("https://old.atlassian.net"))
            #expect(error.localizedDescription.contains("https://example.atlassian.net"))
            #expect(!error.localizedDescription.contains("alice"))
            #expect(!error.localizedDescription.contains("secret"))
        }
        #expect(stub.lastRequest == nil)
    }

    @Test func testIssueSearchAcceptsEquivalentJiraSiteURLs() async throws {
        let project = JiraProjectRef(
            id: "10001",
            key: "SHOP",
            name: "Storefront",
            siteURL: URL(string: "HTTPS://EXAMPLE.ATLASSIAN.NET:443/")!
        )
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }

        _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: [project])

        #expect(stub.lastRequest != nil)
    }

    @Test func testConfiguredSiteIdentityStripsCredentialsAndDefaultPort() {
        let config = JiraConfig(
            siteURL: URL(string: "https://alice:secret@EXAMPLE.ATLASSIAN.NET:443/")!,
            email: "me@example.com",
            token: "tok"
        )

        #expect(config.siteURL == URL(string: "https://example.atlassian.net")!)
    }

    @Test func testProjectsParsesTheVisibleJiraProjects() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "isLast": true,
            "total": 2,
            "values": [
                ["id": "10001", "key": "SHOP", "name": "Storefront"],
                ["id": "10002", "key": "PAY", "name": "Payments"],
            ],
        ])
        let stub = StubSession { _ in (200, body) }
        let projects = try await JiraClient(config: config, session: stub.session).projects()

        #expect(projects == [
            JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: config.siteURL),
            JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: config.siteURL),
        ])
        let request = try #require(stub.lastRequest)
        #expect(request.url?.path == "/rest/api/3/project/search")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "startAt" })?.value == "0")
        #expect(query?.first(where: { $0.name == "maxResults" })?.value == "100")
        #expect(query?.first(where: { $0.name == "orderBy" })?.value == "name")
    }

    @Test func testProjectsLoadsEveryPage() async throws {
        let stub = StubSession { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            let startAt = query?.first(where: { $0.name == "startAt" })?.value
            let object: [String: Any]
            if startAt == "0" {
                object = [
                    "isLast": false,
                    "total": 2,
                    "values": [["id": "10001", "key": "SHOP", "name": "Storefront"]],
                ]
            } else {
                object = [
                    "isLast": true,
                    "total": 2,
                    "values": [["id": "10002", "key": "PAY", "name": "Payments"]],
                ]
            }
            return (200, try! JSONSerialization.data(withJSONObject: object))
        }

        let projects = try await JiraClient(config: config, session: stub.session).projects()

        #expect(projects.map(\.key) == ["SHOP", "PAY"])
        let request = try #require(stub.lastRequest)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "startAt" })?.value == "1")
    }

    @Test func testUnauthorizedMapsToError() async {
        let stub = StubSession { _ in (401, Data()) }
        do { _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(); Issue.record("expected throw") }
        catch let e as JiraError { #expect(e == .unauthorized) } catch { Issue.record("\(error)") }
    }

    /// URLSession re-sends every header on a redirect, so a Jira site that redirected elsewhere
    /// would hand the account's API token to whatever it named.
    @Test func credentialsDoNotFollowARedirectToAnotherHost() async throws {
        let myself = URL(string: "https://example.atlassian.net/rest/api/3/myself")!
        let elsewhere = URL(string: "https://elsewhere.example.com/myself")!
        let stub = RedirectSession(redirects: [myself: elsewhere], body: Data(#"{"displayName":"Me"}"#.utf8))
        #expect(try await JiraClient(config: config, session: stub.session).testConnection() == "Me")
        #expect(stub.requests.map(\.url) == [myself, elsewhere])
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") != nil)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// A search abandoned for a newer one is cancelled, not a network failure to report.
    @Test(arguments: ["worker", "SHOP-2", "2"]) func aCancelledRequestThrowsCancellation(text: String) async {
        let stub = StubSession { _ in (200, Data("{\"issues\":[],\"sections\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.search(text: text)
        }
        await #expect(throws: CancellationError.self) { _ = try await search.value }
    }

    @Test func keySearchRejectsSiteMismatchBeforeSendingRequests() async {
        let stub = StubSession { _ in
            Issue.record("Site mismatch must not send a request")
            return (200, Data())
        }
        let project = JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: URL(string: "https://other.atlassian.net")!)
        await #expect(throws: JiraError.projectSiteMismatch(linked: project.siteURL, configured: config.siteURL)) {
            _ = try await JiraClient(config: config, session: stub.session).search(text: "2", projects: [project])
        }
    }

    /// History suggestions ignore `currentJQL`; Current Search keeps to it, so it is trusted.
    @Test func keySearchDiscardsHistoryFromUnlinkedProjects() async throws {
        let stub = keyStub(picker: ["SHOP-2": ["SHOP-20"]], history: ["SHOP-2": ["SUP-2", "SHOP-21"]], search: { jql in
            jql.contains("key in") ? ["SHOP-20", "SHOP-21"] : []
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-2", projects: [app])
        #expect(tickets.map(\.key) == ["SHOP-20", "SHOP-21"])
        #expect(jqls(stub).contains(#"project in ("SHOP") AND key in ("SHOP-20", "SHOP-21") AND statusCategory != Done"#))
    }

    @Test func malformedPickerResponseIsAnError() async {
        let stub = StubSession { _ in (200, Data(#"{}"#.utf8)) }
        await #expect(throws: JiraError.decoding) {
            _ = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-2")
        }
    }

    var app: JiraProjectRef { JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: config.siteURL) }
    var ops: JiraProjectRef { JiraProjectRef(id: "2", key: "PAY", name: "Payments", siteURL: config.siteURL) }

    /// Answers the picker with `picker[query]` as Current Search and `history[query]` as History,
    /// and a JQL search with a ticket per key `search` returns for it — nil answers HTTP 400.
    private func keyStub(picker: [String: [String]] = [:], history: [String: [String]] = [:],
                         search: @escaping @Sendable (String) -> [String]? = { _ in [] }) -> StubSession {
        StubSession { request in
            if request.url?.path == "/rest/api/3/issue/picker" {
                let query = pickerValue("query", of: request) ?? ""
                let sections = [("cs", picker[query] ?? []), ("hs", history[query] ?? [])].map { id, keys in
                    ["id": id, "issues": keys.map { ["key": $0] }] as [String: Any]
                }
                return (200, try! JSONSerialization.data(withJSONObject: ["sections": sections]))
            }
            guard let keys = search(jqlBody(request) ?? "") else { return (400, Data()) }
            let issues = keys.map { ["key": $0, "fields": ["summary": "Summary of \($0)"]] }
            return (200, try! JSONSerialization.data(withJSONObject: ["issues": issues]))
        }
    }

    private func pickerQueries(_ stub: StubSession) -> [String] {
        stub.requests.compactMap { pickerValue("query", of: $0) }
    }

    private func jqls(_ stub: StubSession) -> [String] { stub.requests.compactMap(jqlBody) }

    private func pickerParameter(_ name: String, _ stub: StubSession) -> String? {
        stub.lastRequest.flatMap { pickerValue(name, of: $0) }
    }

    private func jql(_ stub: StubSession) -> String? { stub.lastRequest.flatMap(jqlBody) }
}

private func pickerValue(_ name: String, of request: URLRequest) -> String? {
    guard let url = request.url, url.path == "/rest/api/3/issue/picker" else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private func jqlBody(_ request: URLRequest) -> String? {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["jql"] as? String
}
