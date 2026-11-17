import Testing
@testable import AiTerm
@testable import AiTermCore

/// The lines under a task row's title: the chip line, or what replaces it while the row is being
/// removed, and the caption under it.
@Suite struct TaskRowCaptionTests {
    @Test func aRemovalReplacesTheChipLineAndHidesTheCaption() {
        let removing = TaskRowCaption(removal: .removing, missing: true)
        #expect(removing == TaskRowCaption(progress: "Removing…", note: nil))
        #expect(TaskRowCaption(removal: .closing, missing: true).progress == "Closing…")
    }

    @Test func anArchivingRowSaysSoInItsBadgeLine() {
        #expect(TaskRowCaption(removal: .archiving, missing: false) == TaskRowCaption(progress: "Archiving…", note: nil))
    }

    @Test func whyARemovalStoppedTakesTheCaptionsPlace() {
        #expect(TaskRowCaption(removal: .stopped(note: "Not removed: branch kept", worktreeRemoved: true), missing: true)
                == TaskRowCaption(progress: nil, note: .warning("Not removed: branch kept")))
    }

    @Test func otherwiseTheCaptionSaysWhatIsMissing() {
        #expect(TaskRowCaption(removal: nil, missing: true).note == .plain("Worktree missing"))
        #expect(TaskRowCaption(removal: nil, missing: false) == TaskRowCaption(progress: nil, note: nil),
                "a row without a window says nothing: the row is drawn as it was")
    }

}

/// A task row's trailing mark: its status's `StatusMark`, the green check once the Operator's work on the task
/// is over, or the pause sign while paused.
@Suite struct TaskRowMarkTests {
    let ended = OperatorLine("merged · 9b3e07d", look: .ended)

    @Test func anEndedTaskShowsTheCheckInPlaceOfItsIdleSessionOrItsUnseenTurn() {
        #expect(TaskRowMark(status: .idle, line: ended, removing: false) == .ended)
        #expect(TaskRowMark(status: .done, line: ended, removing: false) == .ended, "the last turn is the Operator's to read")
    }

    @Test func aSessionInUseARemovalAndEveryOtherLineKeepTheirOwnMark() {
        #expect(TaskRowMark(status: .working, line: ended, removing: false) == .status(.working))
        #expect(TaskRowMark(status: .needsInput, line: ended, removing: false) == .status(.needsInput))
        #expect(TaskRowMark(status: .idle, line: ended, removing: true) == .status(.working), "removing or archiving spins")
        #expect(TaskRowMark(status: .idle, line: OperatorLine("failed · the tests fail"), removing: false) == .status(.idle))
        #expect(TaskRowMark(status: .done, line: OperatorLine("left for you · 4f2a91c", look: .needsYou), removing: false) == .status(.done))
        #expect(TaskRowMark(status: .done, line: nil, removing: false) == .status(.done), "a task of your own")
    }

    @Test func aTaskPausedByYouShowsThePauseSignUnlessItIsBeingRemoved() {
        #expect(TaskRowMark(status: .idle, line: .paused, removing: false, paused: true) == .pauseSign)
        #expect(TaskRowMark(status: .idle, line: .paused, removing: true, paused: true) == .status(.working))
    }
}
