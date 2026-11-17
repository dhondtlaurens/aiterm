import Foundation
import Testing
@testable import AiTermCore

struct GitLabHostRuleTests {
    @Test(arguments: [
        ("https://gitlab.example.net", "https://gitlab.example.net:8443/p", false),
        ("https://gitlab.example.net:8443", "https://gitlab.example.net/p", false),
        ("https://gitlab.example.net:8443", "https://gitlab.example.net:8443/p", true),
        ("https://gitlab.example.net", "https://gitlab.example.net:443/p", true),
        ("https://gitlab.example.net", "http://gitlab.example.net:80/p", true),
        ("https://GitLab.example.net./", "https://GITLAB.example.net/p", true),
        ("https://gitlab.example.net", "https://GitLab.example.net./p", true),
        ("https://gitlab.example.net", "https://other.example.net/p", false),
    ])
    func webAddressesCompareHostAndPort(configured: String, address: String, expected: Bool) throws {
        let config = GitLabConfig(hostURL: try #require(URL(string: configured)), token: "t")
        #expect(config.serves(try #require(URL(string: address))) == expected)
    }

    @Test(arguments: [("GITLAB.example.net", true), ("gitlab.example.net.", true), ("elsewhere.example.net", false)])
    func remoteHostsIgnoreCaseAndTrailingDots(host: String, expected: Bool) {
        let config = GitLabConfig(hostURL: URL(string: "https://GitLab.example.net.:8443")!, token: "t")
        #expect(config.matches(remoteHost: host) == expected)
    }
}
