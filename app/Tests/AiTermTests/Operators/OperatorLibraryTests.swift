import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operators in the sidebar are the files in `operators/` (spec §4.0); a lesson you keep is
/// appended to its operator's file, and the running operation keeps its snapshot (spec §4.5).
@MainActor @Suite struct OperatorLibraryTests {
    let project = OperatorServiceFixtures.project()

    @Test func savedDuplicatedAndTrashedOperatorsAreWhatTheSidebarLists() throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []))
        var heard = 0
        world.controller.onChange { heard += 1 }
        #expect(world.controller.operators.isEmpty)
        try world.controller.saveOperator(OperatorServiceFixtures.persona())
        #expect(world.controller.operators.map(\.handle) == ["senior"])
        #expect(heard == 1)
        try world.controller.duplicateOperator(handle: "senior")
        let copy = try #require(world.controller.operators.first { $0.handle != "senior" })
        #expect(copy.name == "Senior engineer copy" && copy.persona == "You are careful.")
        try world.controller.trashOperator(handle: copy.handle)
        #expect(world.controller.operators.map(\.handle) == ["senior"])
    }

    @Test func operatorsAlreadyInTheFolderAreListedWhenTheControllerStarts() throws {
        let ports = OperatorPorts.scratch()
        try ports.library.save(OperatorServiceFixtures.persona())
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []), adjust: { $0.library = ports.library })
        #expect(world.controller.operators.map(\.handle) == ["senior"])
    }

    @Test func aKeptLessonJoinsTheOperatorsFileAndADismissedOneDoesNot() throws {
        var run = OperatorServiceFixtures.run(projects: [project], state: .active)
        run.lessons = [ProposedLesson(key: "l1", lesson: "Ask before a migration.", because: "You overruled me."),
                       ProposedLesson(key: "l2", lesson: "Never test.", because: "Faster.")]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        try world.controller.saveOperator(OperatorServiceFixtures.persona())
        try world.controller.decideLesson(run: run.id, key: "l1", .kept, edited: "Ask before any migration.")
        try world.controller.decideLesson(run: run.id, key: "l2", .dismissed, edited: nil)
        #expect(world.controller.operators.first?.lessons == ["Ask before any migration."])
        #expect(world.run(run.id)?.lessons.map(\.decided) == [.kept, .dismissed])
        #expect(world.run(run.id)?.lessons.first?.lesson == "Ask before any migration.")
        #expect(world.run(run.id)?.persona.lessons == [], "the running operation keeps its snapshot")
    }

    @Test func twoLessonsKeptInARowForOneOperatorBothReachItsFile() throws {
        var first = OperatorServiceFixtures.run(projects: [project], state: .active)
        first.lessons = [ProposedLesson(key: "a", lesson: "Run the linter.", because: "It was missed.")]
        var second = OperatorServiceFixtures.run(projects: [project], state: .active)
        second.lessons = [ProposedLesson(key: "b", lesson: "Name the migration.", because: "It was vague."),
                          ProposedLesson(key: "c", lesson: "Commit small.", because: "A big diff.")]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [first, second]))
        try world.controller.saveOperator(OperatorServiceFixtures.persona())
        try world.controller.decideLesson(run: first.id, key: "a", .kept, edited: nil)
        try world.controller.decideLesson(run: second.id, key: "b", .kept, edited: nil)
        try world.controller.decideLesson(run: second.id, key: "c", .kept, edited: nil)
        let onDisk = try #require(world.ports.library.load().operators.first { $0.handle == "senior" })
        #expect(onDisk.lessons == ["Run the linter.", "Name the migration.", "Commit small."])
        #expect(world.controller.operators.first?.lessons == onDisk.lessons)
    }

    @Test func aLessonDecidedTwiceIsAppendedOnceAndTheFirstDecisionStands() throws {
        var run = OperatorServiceFixtures.run(projects: [project], state: .active)
        run.lessons = [ProposedLesson(key: "l1", lesson: "Ask first.", because: "Overruled.")]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        try world.controller.saveOperator(OperatorServiceFixtures.persona())
        try world.controller.decideLesson(run: run.id, key: "l1", .kept, edited: nil)
        try world.controller.decideLesson(run: run.id, key: "l1", .kept, edited: "Ask first, always.")
        try world.controller.decideLesson(run: run.id, key: "l1", .dismissed, edited: nil)
        #expect(world.controller.operators.first?.lessons == ["Ask first."])
        #expect(world.run(run.id)?.lessons.first?.decided == .kept)
        #expect(world.run(run.id)?.lessons.first?.lesson == "Ask first.")
    }

    @Test func aLessonForAnOperatorTrashedSinceStaysUndecidedAndSaysSo() throws {
        var run = OperatorServiceFixtures.run(projects: [project], state: .active)
        run.lessons = [ProposedLesson(key: "l1", lesson: "Ask first.", because: "Overruled.")]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        #expect(throws: (any Error).self) { try world.controller.decideLesson(run: run.id, key: "l1", .kept, edited: nil) }
        #expect(world.run(run.id)?.lessons.first?.decided == nil)
    }

    @Test func savingOrTrashingAnOperatorLeavesEveryRunsSnapshotAlone() throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        var changed = OperatorServiceFixtures.persona()
        changed.persona = "You are reckless."
        changed.lessons = ["Something new."]
        try world.controller.saveOperator(changed)
        #expect(world.run(run.id)?.persona == OperatorServiceFixtures.persona())
        try world.controller.trashOperator(handle: "senior")
        #expect(world.controller.operators.isEmpty)
        #expect(world.run(run.id)?.persona == OperatorServiceFixtures.persona())
    }
}
