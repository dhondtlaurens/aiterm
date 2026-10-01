import Testing
import AiTermCore
@testable import AiTerm

/// The iTerm card names the first broken link between AiTerm and iTerm2, and says how to mend it.
@Suite struct ItermSettingsTests {
    private let healthy = ItermEnvironment(installed: true, pythonAPIEnabled: true)

    private func card(_ connection: ItermConnection, _ environment: ItermEnvironment? = nil,
                      testing: Bool = false) -> ItermCard {
        ItermCardPresentation.card(for: connection, environment: environment ?? healthy, testing: testing)
    }

    @Test func aLiveConnectionNamesTheITerm2VersionAndNeedsNoSteps() {
        #expect(card(.connected(version: "3.7.2")) == ItermCard(status: SettingsStatus(.ready, "Connected to iTerm2 3.7.2")))
        #expect(card(.connected(version: nil)).status == SettingsStatus(.ready, "Connected to iTerm2"))
    }

    @Test func statesThatClearOnTheirOwnStayGreyWithoutSteps() {
        for connection in [ItermConnection.starting, .helperUnreachable, .waitingForIterm, .itermReconnecting] {
            #expect(card(connection).status.tone == .idle, "\(connection)")
            #expect(card(connection).steps.isEmpty, "\(connection)")
        }
    }

    @Test func aHelperProblemIsNamedBeforeAnythingAboutITerm2() {
        let nothingWorks = ItermEnvironment(installed: false, pythonAPIEnabled: false)
        #expect(card(.pythonMissing, nothingWorks).status == SettingsStatus(.attention, "Python 3.11+ was not found"))
        #expect(card(.pythonMissing).steps.first == "Install it with brew install python")
        #expect(card(.helperMissing, nothingWorks).status.tone == .attention)
        #expect(card(.helperMismatch, nothingWorks).steps == ["Quit and reopen AiTerm.app"])
        let failing = card(.helperFailing("exited with status 1"))
        #expect(failing.status == SettingsStatus(.attention, "AiTerm’s helper keeps stopping: exited with status 1"))
        #expect(failing.steps.first?.contains(ItermConnection.logPath) == true)
    }

    @Test func iTerm2ItselfAnswersWhatTheHelperCannotTellApart() {
        let missing = card(.waitingForIterm, ItermEnvironment(installed: false, pythonAPIEnabled: false))
        #expect(missing.status == SettingsStatus(.attention, "iTerm2 is not installed"))
        #expect(missing.steps.count == 3)

        let apiOff = ItermEnvironment(installed: true, pythonAPIEnabled: false)
        for connection in [ItermConnection.waitingForIterm, .itermReconnecting, .refused("-1743")] {
            #expect(card(connection, apiOff).status == SettingsStatus(.attention, "iTerm2’s Python API is off"), "\(connection)")
            #expect(card(connection, apiOff).steps == [
                "Open iTerm2 › Settings › General › Magic",
                "Turn on “Enable Python API”",
                "AiTerm reconnects on its own within a few seconds",
            ])
        }
        // A connection is proof enough; a stale preference read does not argue with it.
        #expect(card(.connected(version: "3.7.2"), apiOff).status.tone == .ready)
    }

    @Test func aRefusalWithTheAPIOnPointsAtAutomation() {
        let refused = card(.refused("Not authorized to send Apple events to iTerm2. (-1743)"))
        #expect(refused.status == SettingsStatus(.attention, "iTerm2 refused the connection: Not authorized to send Apple events to iTerm2. (-1743)"))
        #expect(refused.steps.first == "Open System Settings › Privacy & Security › Automation")
    }

    @Test func beforeTheFirstCheckOnlyTheHelpersViewIsShown() {
        let unchecked = ItermCardPresentation.card(for: .waitingForIterm, environment: nil, testing: false)
        #expect(unchecked == ItermCard(status: SettingsStatus(.idle, "Waiting for iTerm2…")))
    }

    @Test func aRunningTestKeepsTheStepsSoTheCardDoesNotJump() {
        let apiOff = ItermEnvironment(installed: true, pythonAPIEnabled: false)
        let testing = card(.waitingForIterm, apiOff, testing: true)
        #expect(testing.status == SettingsStatus(.idle, "Testing…"))
        #expect(testing.steps == card(.waitingForIterm, apiOff).steps)
    }
}
