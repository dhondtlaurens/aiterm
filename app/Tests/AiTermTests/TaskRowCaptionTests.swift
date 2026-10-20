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
        for line in [OperatorLine("working", look: .acting), OperatorLine("queued · after PAY-232"), OperatorLine("done · 4f2a91c")] {
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
