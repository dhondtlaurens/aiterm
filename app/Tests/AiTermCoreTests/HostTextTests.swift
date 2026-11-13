import Foundation
import Testing
@testable import AiTermCore

@Suite struct HostTextTests {
    @Test func numberParsingKeepsEachHostsCurrentRule() {
        func github(_ text: String) -> Int? {
            guard text.range(of: #"^[#!]?\d+$"#, options: .regularExpression) != nil else { return nil }
            return Int(text.drop { $0 == "#" || $0 == "!" })
        }
        func mergeRequest(_ text: String) -> Int? {
            guard text.range(of: #"^!?\d+$"#, options: .regularExpression) != nil else { return nil }
            return Int(text.hasPrefix("!") ? String(text.dropFirst()) : text)
        }
        func issue(_ text: String) -> Int? {
            guard text.range(of: #"^#?\d+$"#, options: .regularExpression) != nil else { return nil }
            return Int(text.drop { $0 == "#" })
        }
        let rows = ["", "0", "00012", "87", "#87", "!87", "##87", "!!87", "#!87", "!#87", " 87", "87 ",
                    "87\n", "87\r\n", "87\n9", "+87", "-87", "٨٧", "８７", "1_000", String(Int.max),
                    String(Int.max) + "0", "#" + String(Int.max), "!" + String(Int.max), "#", "!"]
        for text in rows {
            #expect(GitHubClient.number(text) == github(text), "GitHub: \(text.debugDescription)")
            #expect(GitLabClient.iid(text) == mergeRequest(text), "GitLab request: \(text.debugDescription)")
            #expect(GitLabClient.issueNumber(text) == issue(text), "GitLab issue: \(text.debugDescription)")
        }
    }

    @Test func branchNamesKeepTheCurrentSinglePrefixRule() {
        for branch in ["", "main", "refs/heads/", "refs/heads/main", "refs/heads/refs/heads/main", " refs/heads/main", "refs/heads/main\n", "REFS/heads/main", "refs/tags/main", "é/开发"] {
            let current = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
            #expect(Data(HostText.branchName(branch).utf8) == Data(current.utf8))
        }
    }

    @Test func protectionWrappingKeepsTheCurrentPunctuationAndWhitespace() {
        let reasons: [String?] = [nil, "", " . denied. . ", "\tdenied.\n", "...", " é. ", "e\u{301}."]
        for reason in reasons {
            for context in ["AiTerm could not read GitHub’s protection of main in owner/repo", "AiTerm could not read the protected branches of the GitLab group owner"] {
                let why = (reason ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                let current = ProtectionUnknown.unreadable("\(context): \(why)")
                #expect(Data(HostText.protectionFailure(context, reason: reason).localizedDescription.utf8) == Data(current.localizedDescription.utf8))
            }
        }
    }

    @Test func shortPagingKeepsTheCurrentRequestsAndTerminalRule() async throws {
        func current(_ raw: [[Int]], perPage: Int, pages: Int) -> (items: [Int], complete: Bool, reads: [Int]) {
            var all: [Int] = [], reads: [Int] = []
            for page in 1...max(1, pages) {
                reads.append(page)
                let batch = page <= raw.count ? raw[page - 1] : []
                all += batch
                if batch.count < perPage { return (all, true, reads) }
            }
            return (all, false, reads)
        }
        for raw in [[], [[]], [[1, 2], [3]], [[1, 2], [3, 4], []]] as [[[Int]]] {
            for perPage in [-1, 0, 1, 2, 3] {
                for pages in [-1, 0, 1, 2, 3] {
                    var reads: [Int] = []
                    let result = try await HTTPJSON.shortPages(perPage: perPage, pages: pages) { page in
                        reads.append(page)
                        return page <= raw.count ? raw[page - 1] : []
                    }
                    let reference = current(raw, perPage: perPage, pages: pages)
                    #expect(result.items == reference.items)
                    #expect(result.complete == reference.complete)
                    #expect(reads == reference.reads)
                }
            }
        }
    }
}
