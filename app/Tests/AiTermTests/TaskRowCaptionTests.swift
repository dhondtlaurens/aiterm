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
        #expect(TaskRowCaption(removal: .stopped(note: "Not removed: iTerm2 isn’t connected"), missing: true)
                == TaskRowCaption(progress: nil, note: .warning("Not removed: iTerm2 isn’t connected")))
    }

    @Test func otherwiseTheCaptionSaysWhatIsMissing() {
        #expect(TaskRowCaption(removal: nil, missing: true).note == .plain("Worktree missing"))
        #expect(TaskRowCaption(removal: nil, missing: false) == TaskRowCaption(progress: nil, note: nil),
                "a row without a window says nothing: the row is drawn as it was")
    }

}
