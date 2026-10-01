import CoreServices
import Testing
@testable import AiTermCore
@testable import AiTerm

@Suite struct ItermCookieTests {
    @Test func aReplyIsACookieAndAKey() {
        #expect(ItermCookie.answer(forReply: "c00kie k3y") == .granted(cookie: "c00kie", key: "k3y"))
        let garbled = ItermCookieAnswer.refused("iTerm2 answered the cookie request with something other than a cookie and key")
        #expect(ItermCookie.answer(forReply: "c00kie") == garbled)
        #expect(ItermCookie.answer(forReply: nil) == garbled)
    }

    @Test func errorsReadTheWayOsascriptsDid() {
        #expect(ItermCookie.answer(forError: Int(errAEEventNotPermitted)) == .refused("Not authorized to send Apple events to iTerm2. (-1743)"))
        #expect(ItermCookie.answer(forError: Int(procNotFound)) == .notRunning)
        #expect(ItermCookie.answer(forError: -10000, detail: "The API server is off.") == .refused("The API server is off. (-10000)"))
    }
}
