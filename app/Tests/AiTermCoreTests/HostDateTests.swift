import Foundation
import Testing
@testable import AiTermCore

struct HostDateTests {
    @Test func hostTimesKeepTheirOffsetsAndFractionalSeconds() throws {
        let whole = Date(timeIntervalSince1970: 1_793_692_052)
        #expect(abs(try #require(HostDate.iso8601("2026-11-03T07:47:32.776Z")).timeIntervalSince(whole) - 0.776) < 0.000001)
        #expect(HostDate.iso8601("2026-11-03T08:47:32+01:00") == whole)
        #expect(abs(try #require(HostDate.jira("2026-11-03T08:47:32.776+0100")).timeIntervalSince(whole) - 0.776) < 0.000001)
        #expect(HostDate.iso8601("bad time") == nil)
        #expect(HostDate.jira("bad time") == nil)
        #expect(HostDate.iso8601String(from: whole.addingTimeInterval(0.776)) == "2026-11-03T07:47:32Z")
    }
}
