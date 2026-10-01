import Testing
@testable import AiTermCore

@Suite struct ReleaseVersionTests {
    @Test func parsesWithAndWithoutPrefix() {
        #expect(ReleaseVersion("v0.2.0") == ReleaseVersion(major: 0, minor: 2, patch: 0))
        #expect(ReleaseVersion("1.10.3") == ReleaseVersion(major: 1, minor: 10, patch: 3))
        #expect(ReleaseVersion(" v2.0.1 ")?.description == "2.0.1")
    }

    @Test func ordersNumericallyNotAsText() throws {
        #expect(try #require(ReleaseVersion("0.10.0")) > #require(ReleaseVersion("0.9.2")))
        #expect(try #require(ReleaseVersion("1.0.0")) > #require(ReleaseVersion("0.99.99")))
        #expect(try #require(ReleaseVersion("0.2.1")) > #require(ReleaseVersion("0.2.0")))
    }

    @Test func rejectsAnythingElse() {
        for junk in ["", "v", "1.2", "1.2.3.4", "1.2.x", "v1.2.3-beta", "+1.2.3", "1..3", "latest", "V1.2.3"] {
            #expect(ReleaseVersion(junk) == nil, "\(junk)")
        }
    }
}
