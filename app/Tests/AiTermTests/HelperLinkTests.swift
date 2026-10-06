import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct HelperLinkTests {
    private func link(preferences: InterfacePreferences? = nil, notices: Notices? = nil) -> HelperLink {
        HelperLink(bundledResourcesURL: nil, preferences: preferences ?? .scratch(), notices: notices ?? .aboutNoRows())
    }

    private let title = SessionTitle(sessionId: "s", title: "feat/a")

    /// The daemon alone knows which titles iTerm2 has: it skips one already applied, forgets a
    /// tab's when the tab moves and all of them when iTerm2 reconnects. So every pass sends the
    /// whole list, whatever was sent before, and the app has nothing to infer or to get wrong.
    @Test func everyPassSendsItsTitlesAndTheDaemonDecidesWhichToApply() async {
        let daemon = RecordingDaemon()
        let link = link()
        link.setDaemonClient(daemon)
        func sends() -> Int { daemon.requests("sessions.setTitles").count }

        await link.sendTitles([title])
        await link.sendTitles([title])
        #expect(sends() == 2)
        await link.sendTitles([])
        #expect(sends() == 2, "no titles, nothing to send")
    }

    /// A pass that ends with no daemon attached has nowhere to send, and the next one after it does.
    @Test func titlesGoToTheDaemonAttachedWhenThePassEnds() async {
        let first = RecordingDaemon(), second = RecordingDaemon()
        let link = link()
        await link.sendTitles([title])
        link.setDaemonClient(first)
        await link.sendTitles([title])
        link.setDaemonClient(second)
        await link.sendTitles([title])

        #expect(first.requests("sessions.setTitles").count == 1)
        #expect(second.requests("sessions.setTitles").count == 1)
    }

    /// A bundle without the helper is known at once: finding Python first is a login shell for
    /// nothing, and a test that starts a helper would run one.
    @Test func aMissingHelperIsReportedWithoutLookingForPython() {
        let lookups = Mutex(0)
        let link = HelperLink(bundledResourcesURL: nil, preferences: .scratch(),
                              findPython: { lookups.withLock { $0 += 1 }; return nil },
                              notices: .aboutNoRows())
        link.start()
        defer { link.shutdown() }
        #expect(link.itermConnection == .helperMissing)
        #expect(lookups.withLock { $0 } == 0)
    }

    /// A send that failed applied nothing, and the next pass sends again as it does after any.
    @Test func aTitleTheDaemonRefusedIsSentAgain() async {
        let daemon = RecordingDaemon(failing: ["sessions.setTitles": "temporary_failure"])
        let link = link()
        link.setDaemonClient(daemon)

        await link.sendTitles([title])
        await link.sendTitles([title])

        #expect(daemon.requests("sessions.setTitles").count == 2)
    }

    /// Nobody waits on the background send, so its failure goes to the banner.
    @Test func aBackgroundTheDaemonRefusedIsReported() async {
        let daemon = RecordingDaemon(failing: ["interface.setMatchItermBackground": "temporary_failure"])
        let notices = Notices.aboutNoRows()
        let preferences = InterfacePreferences.scratch()
        let link = link(preferences: preferences, notices: notices)
        link.setDaemonClient(daemon)

        await link.setMatchItermBackground(!preferences.matchItermBackground)?.value

        #expect(notices.issue == OperationIssue(title: "Couldn’t update the iTerm2 background.", reason: "AiTerm’s helper ran into a problem."))
    }
}

private extension Notices {
    /// Notices with no workspace behind them: nothing they are told about is ever gone.
    static func aboutNoRows() -> Notices {
        Notices(toastLifetime: .seconds(10), isStale: { _ in false })
    }
}
