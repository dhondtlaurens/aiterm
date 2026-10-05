import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct HelperLinkTests {
    private func link(preferences: InterfacePreferences? = nil,
                      errors: @escaping @MainActor (OperationIssue) -> Void = { _ in }) -> HelperLink {
        HelperLink(bundledResourcesURL: nil, preferences: preferences ?? .scratch(), onEvent: { _ in }, onAttach: {},
                   reportError: errors)
    }

    private let tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: UUID().uuidString, projectId: nil,
                                  agent: .claude, model: nil, state: .idle, title: "", cwd: "/repo")
    private let title = SessionTitle(sessionId: "s", title: "feat/a")

    /// The daemon alone knows which titles iTerm2 has: it skips one already applied, forgets a
    /// tab's when the tab moves and all of them when iTerm2 reconnects. So every pass sends the
    /// whole list, whatever was sent before, and the app has nothing to infer or to get wrong.
    @Test func everyPassSendsItsTitlesAndTheDaemonDecidesWhichToApply() async {
        let daemon = RecordingDaemon()
        let link = link()
        link.setDaemonClient(daemon)
        func sends() -> Int { daemon.requests("sessions.setTitles").count }

        await link.sendTitles([title], placedIn: [tab])
        await link.sendTitles([title], placedIn: [tab])
        #expect(sends() == 2)
        var moved = tab
        moved.tabIndex = 1
        await link.sendTitles([title], placedIn: [moved])
        #expect(sends() == 3)
        link.handle(.itermConnected("3.7.2"))
        await link.sendTitles([title], placedIn: [moved])
        #expect(sends() == 4)
        await link.sendTitles([], placedIn: [])
        #expect(sends() == 4, "no titles, nothing to send")
    }

    /// A pass that ends with no daemon attached has nowhere to send, and the next one after it does.
    @Test func titlesGoToTheDaemonAttachedWhenThePassEnds() async {
        let first = RecordingDaemon(), second = RecordingDaemon()
        let link = link()
        await link.sendTitles([title], placedIn: [tab])
        link.setDaemonClient(first)
        await link.sendTitles([title], placedIn: [tab])
        link.setDaemonClient(second)
        await link.sendTitles([title], placedIn: [tab])

        #expect(first.requests("sessions.setTitles").count == 1)
        #expect(second.requests("sessions.setTitles").count == 1)
    }

    /// A bundle without the helper is known at once: finding Python first is a login shell for
    /// nothing, and a test that starts a helper would run one.
    @Test func aMissingHelperIsReportedWithoutLookingForPython() {
        let lookups = Mutex(0)
        let link = HelperLink(bundledResourcesURL: nil, preferences: .scratch(),
                              findPython: { lookups.withLock { $0 += 1 }; return nil },
                              onEvent: { _ in }, onAttach: {}, reportError: { _ in })
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

        await link.sendTitles([title], placedIn: [tab])
        await link.sendTitles([title], placedIn: [tab])

        #expect(daemon.requests("sessions.setTitles").count == 2)
    }

    /// Nobody waits on the background send, so its failure is reported to the controller.
    @Test func aBackgroundTheDaemonRefusedIsReported() async {
        let daemon = RecordingDaemon(failing: ["interface.setMatchItermBackground": "temporary_failure"])
        var errors: [OperationIssue] = []
        let preferences = InterfacePreferences.scratch()
        let link = link(preferences: preferences, errors: { errors.append($0) })
        link.setDaemonClient(daemon)

        await link.setMatchItermBackground(!preferences.matchItermBackground)?.value

        #expect(errors == [OperationIssue(title: "Couldn’t update the iTerm2 background.", reason: "test failure")])
    }
}
