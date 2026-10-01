import Testing
@testable import AiTerm

/// The lines under a task row's title: the chip line, or what replaces it while the row is being
/// removed, and the caption under it.
@Suite struct TaskRowCaptionTests {
    @Test func aRemovalReplacesTheChipLineAndHidesTheCaption() {
        let removing = TaskRowCaption(removal: .removing, missing: true, windowOpen: false)
        #expect(removing == TaskRowCaption(progress: "Removing…", note: nil))
        #expect(TaskRowCaption(removal: .closing, missing: true, windowOpen: false).progress == "Closing…")
    }

    @Test func whyARemovalStoppedTakesTheCaptionsPlace() {
        #expect(TaskRowCaption(removal: .stopped(note: "Not removed: branch kept", worktreeRemoved: true), missing: true, windowOpen: false)
                == TaskRowCaption(progress: nil, note: .warning("Not removed: branch kept")))
    }

    @Test func otherwiseTheCaptionSaysWhatIsMissing() {
        #expect(TaskRowCaption(removal: nil, missing: true, windowOpen: false).note == .plain("Worktree missing"))
        #expect(TaskRowCaption(removal: nil, missing: false, windowOpen: false).note == .plain("Window closed"))
        #expect(TaskRowCaption(removal: nil, missing: false, windowOpen: true) == TaskRowCaption(progress: nil, note: nil))
    }
}
