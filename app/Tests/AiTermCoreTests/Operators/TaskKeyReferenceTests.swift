import Testing
import Foundation
@testable import AiTermCore

/// A wake line names a task by its key as the Operator's tools take it (broadcast "Broadcast fix", 2026-11-05): area-E
/// was spoken `area-letter-ee` and area-G `area-letter-gee`, keys no tool accepted. A key keeps its letters as written,
/// its digits spelled (no wake line carries a digit), and a tool resolves that spoken form back to the task.
@Suite struct TaskKeyReferenceTests {
    @Test(arguments: [
        ("area-E", "area-E"), ("area-G", "area-G"), ("T7", "T-seven"), ("T10", "T-one-zero"), ("PAY-2", "PAY-two"),
        ("A", "letter-ay"), ("e", "letter-ee"), ("7", "seven"), ("fix_db", "fix-db"), ("", "task"),
    ])
    func aKeyIsSpokenAsTheToolsTakeIt(key: String, spoken: String) {
        #expect(TaskKeyReference.spoken(key) == spoken)
    }

    /// The tools resolve a task by its key or id first, then by the one task whose spoken key the reference is.


    /// Two keys spoken alike resolve neither by that form: only their own keys name them.


    /// A key spelled exactly as another task's spoken form is that task's: an exact key wins.

}
