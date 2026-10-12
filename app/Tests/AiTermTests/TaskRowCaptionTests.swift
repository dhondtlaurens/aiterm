import Testing
@testable import AiTerm

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
}
