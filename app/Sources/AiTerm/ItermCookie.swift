import AppKit
import CoreServices
import AiTermCore

/// Asks iTerm2 for a Python API cookie on the helper's behalf, as `request cookie and key for app
/// named "aitermd"` would. It is an Apple event sent from this process, not an osascript child:
/// macOS counts every process AiTerm starts as AiTerm, so each osascript the helper ran checked in
/// as a second foreground AiTerm and bounced an icon of its own in the Dock. Sending it from here
/// also keeps the Automation permission where it already was, on AiTerm.
enum ItermCookie {
    /// The name iTerm2 lists the connection under in its Scripts console: the helper's, as when it
    /// asked for itself.
    static let appName = "aitermd"

    /// Blocks until iTerm2 answers, which the first time waits on macOS's Automation prompt, so it
    /// runs off the main thread.
    static func request() async -> ItermCookieAnswer {
        await BackgroundWork.run { requestNow() }
    }

    private static func requestNow() -> ItermCookieAnswer {
        let iterm = ItermPreferences.bundleIdentifier
        // An event to an app that is not running fails rather than launching it; say so up front,
        // as the osascript "is it running" check did, so the helper opens iTerm2 itself.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: iterm).isEmpty else { return .notRunning }
        let event = NSAppleEventDescriptor(eventClass: fourCharCode("Itrm"), eventID: fourCharCode("rqck"),
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: iterm),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: appName), forKeyword: fourCharCode("Rcsn"))
        let reply: NSAppleEventDescriptor
        do { reply = try event.sendEvent(options: [.waitForReply], timeout: timeout) }
        catch { return answer(forError: (error as NSError).code) }
        if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != noErr {
            return answer(forError: Int(code), detail: reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue)
        }
        return answer(forReply: reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue)
    }

    /// Long enough for someone to answer the first Automation prompt, which the send waits on.
    static let timeout: TimeInterval = 120

    /// iTerm2 replies `"<cookie> <key>"`.
    static func answer(forReply text: String?) -> ItermCookieAnswer {
        let parts = (text ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            // Never echo the reply: half of a cookie is still a credential.
            return .refused("iTerm2 answered the cookie request with something other than a cookie and key")
        }
        return .granted(cookie: parts[0], key: parts[1])
    }

    /// The reasons read the way osascript's did, which the sidebar banner already quotes.
    static func answer(forError code: Int, detail: String? = nil) -> ItermCookieAnswer {
        switch code {
        case Int(procNotFound), Int(connectionInvalid): return .notRunning
        case Int(errAEEventNotPermitted): return .refused("Not authorized to send Apple events to iTerm2. (\(code))")
        case Int(errAETimeout): return .refused("iTerm2 did not answer the cookie request. (\(code))")
        default: return .refused("\(detail ?? "iTerm2 refused the cookie request.") (\(code))")
        }
    }

    private static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
