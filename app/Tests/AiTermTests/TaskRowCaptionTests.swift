import Testing
@testable import AiTerm
@testable import AiTermCore

/// The lines under a task row's title: the chip line, or what replaces it while the row is being
/// removed, and the caption under it.
@Suite struct TaskRowCaptionTests {
    @Test func aRemovalReplacesTheChipLineAndHidesTheCaption() {
        let removing = TaskRowCaption(removal: .removing, missing: true, failed: false)
        #expect(removing == TaskRowCaption(progress: "Removing…", note: nil))
        #expect(TaskRowCaption(removal: .closing, missing: true, failed: false).progress == "Closing…")
    }

    @Test func anArchivingRowSaysSoInItsBadgeLine() {
        #expect(TaskRowCaption(removal: .archiving, missing: false, failed: false) == TaskRowCaption(progress: "Shelving…", note: nil))
    }

    @Test func whyARemovalStoppedTakesTheCaptionsPlace() {
        #expect(TaskRowCaption(removal: .stopped(note: "Not removed: branch kept", worktreeRemoved: true), missing: true, failed: false)
                == TaskRowCaption(progress: nil, note: .warning("Not removed: branch kept")))
    }

    @Test func otherwiseTheCaptionSaysWhatIsMissing() {
        #expect(TaskRowCaption(removal: nil, missing: true, failed: true).note == .plain("Worktree missing"))
        #expect(TaskRowCaption(removal: nil, missing: false, failed: true).note == .plain("Couldn’t reopen"))
        #expect(TaskRowCaption(removal: nil, missing: false, failed: false) == TaskRowCaption(progress: nil, note: nil),
                "an owed window coming back says nothing: the row is drawn as it was")
    }

    /// While the Operator holds a task and nothing on it is yours, the badge line folds away under its
    /// status line; what is yours to act on unfolds it, and so does anything the caption says.
    @Test func theBadgeLineFoldsUnderTheOperatorUntilItIsYours() {
        let plain = TaskRowCaption(removal: nil, missing: false, failed: false)
        for line in [OperatorLine("working", look: .acting), OperatorLine("queued · after PAY-232"), OperatorLine("done · 4f2a91c", look: .ended)] {
            #expect(plain.folds(under: line), "\(line.text)")
        }
        #expect(!plain.folds(under: OperatorLine("waiting on you", look: .needsYou)))
        #expect(!plain.folds(under: OperatorLine("left for you · 4f2a91c", look: .needsYou)))
        #expect(!plain.folds(under: nil), "a task of your own keeps its badges")
        let working = OperatorLine("working", look: .acting)
        #expect(!TaskRowCaption(removal: .removing, missing: false, failed: false).folds(under: working), "Removing… is the badge line's")
        #expect(!TaskRowCaption(removal: nil, missing: true, failed: false).folds(under: working), "the note takes the status line's place")
    }
}

/// A task row's trailing mark: its sessions' `StatusMark`, or the green check once the Operator's work on the
/// task is over (1A, 21 Oct 2026).
@Suite struct TaskRowMarkTests {
    let ended = OperatorLine("merged · 9b3e07d", look: .ended)

    @Test func anEndedTaskShowsTheCheckInPlaceOfItsIdleSessionOrItsUnseenTurn() {
        #expect(TaskRowMark(status: .idle, line: ended, removing: false) == .ended)
        #expect(TaskRowMark(status: .done, line: ended, removing: false) == .ended, "the last turn is the Operator's to read")
    }

    @Test func aSessionInUseARemovalAndEveryOtherLineKeepTheirOwnMark() {
        #expect(TaskRowMark(status: .working, line: ended, removing: false) == .status(.working))
        #expect(TaskRowMark(status: .needsInput, line: ended, removing: false) == .status(.needsInput))
        #expect(TaskRowMark(status: .idle, line: ended, removing: true) == .status(.working), "removing or shelving spins")
        #expect(TaskRowMark(status: .idle, line: OperatorLine("failed · the tests fail"), removing: false) == .status(.idle))
        #expect(TaskRowMark(status: .done, line: OperatorLine("left for you · 4f2a91c", look: .needsYou), removing: false) == .status(.done))
        #expect(TaskRowMark(status: .done, line: nil, removing: false) == .status(.done), "a task of your own")
    }
}
