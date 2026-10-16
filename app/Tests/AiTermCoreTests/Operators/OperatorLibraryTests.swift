import Testing
import Foundation
@testable import AiTermCore

@Suite struct OperatorLibraryTests {
    /// A library in a folder of its own, whose Trash is a folder beside it: a test never touches
    /// the developer's operators or their Trash.
    private func scratch() -> (OperatorLibrary, root: URL, trash: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operators-\(UUID().uuidString)")
        let trash = root.appendingPathComponent("Trash")
        let library = OperatorLibrary(directory: root.appendingPathComponent("operators")) { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        return (library, root, trash)
    }

    private func persona(_ name: String, _ handle: String) -> OperatorPersona {
        OperatorPersona(name: name, handle: handle, model: "opus", effort: "high", secondOpinion: .standard,
                        autonomy: .routine, persona: "Be careful.")
    }

    @Test func theFolderIsOperatorsInAiTermsSupportFolder() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(OperatorLibrary.defaultDirectory(home: home).path == "/Users/someone/Library/Application Support/AiTerm/operators")
    }

    @Test func aMissingFolderIsAnEmptyLibrary() {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(library.load() == OperatorLibrary.Loaded(operators: [], unreadable: []))
    }

    @Test func savedOperatorsLoadBackSortedByName() throws {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(persona("Reviewer", "reviewer"))
        try library.save(persona("Architect", "architect"))
        try library.save(persona("architect 10", "architect-10"))
        try library.save(persona("Architect 9", "architect-9"))

        #expect(library.load().operators.map(\.handle) == ["architect", "architect-9", "architect-10", "reviewer"])
        #expect(FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("reviewer.md").path))
    }

    /// The file's name is the handle: a file copied by hand under a new name is a second operator,
    /// not a duplicate of the first.
    @Test func theFileNameIsTheHandle() throws {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(persona("Senior", "senior"))
        try FileManager.default.copyItem(at: library.url(for: "senior"), to: library.url(for: "senior-copy"))

        #expect(library.load().operators.map(\.handle) == ["senior", "senior-copy"])
    }

    @Test func aFileThatIsNotAnOperatorIsReportedAndTheRestLoad() throws {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(persona("Senior", "senior"))
        try Data("no frontmatter".utf8).write(to: library.url(for: "broken"))
        try Data("---\nname: n\nhandle: x\nmodel: m\n---\n".utf8).write(to: library.directory.appendingPathComponent("Bad Name.md"))
        try Data("ignored".utf8).write(to: library.directory.appendingPathComponent("notes.txt"))

        let loaded = library.load()
        #expect(loaded.operators.map(\.handle) == ["senior"])
        #expect(loaded.unreadable.map(\.file.lastPathComponent) == ["Bad Name.md", "broken.md"])
        #expect(loaded.unreadable.last?.reason == OperatorFile.ParseError.missingFrontmatter.description)
    }

    @Test func aSaveReplacesTheFileWhole() throws {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = persona("Senior", "senior")
        try library.save(p)
        p.autonomy = .handsOff
        try library.save(p)
        #expect(library.load().operators == [p])
    }

    @Test(arguments: ["", "Upper", "has space", "-lead", "trail-", "a/b", "..", String(repeating: "a", count: 65)])
    func anInvalidHandleIsNeverWritten(_ handle: String) {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: OperatorLibrary.Failure.invalidHandle(handle)) { try library.save(persona("X", handle)) }
    }

    @Test func trashMovesTheFileToTheTrashAndOutOfTheLibrary() throws {
        let (library, root, trash) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(persona("Senior", "senior"))

        let moved = try library.trash(handle: "senior")

        #expect(moved == trash.appendingPathComponent("senior.md"))
        #expect(library.load().operators.isEmpty)
        #expect(throws: OperatorLibrary.Failure.notFound("senior")) { try library.trash(handle: "senior") }
    }

    @Test func aKeptLessonIsAppendedToTheFileOnce() throws {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(persona("Senior", "senior"))

        try library.appendLesson("  Ask before adding a field.\n", to: "senior")
        try library.appendLesson("Ask before adding a field.", to: "senior")

        #expect(library.load().operators.first?.lessons == ["Ask before adding a field."])
        #expect(throws: OperatorLibrary.Failure.notFound("ghost")) { try library.appendLesson("x", to: "ghost") }
    }

    @Test func aNewHandleComesFromTheNameAndSkipsTheTakenOnes() throws {
        let (library, root, _) = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(library.uniqueHandle(for: "Senior Engineer") == "senior-engineer")
        #expect(library.uniqueHandle(for: "Café — Ops!") == "cafe-ops")
        #expect(library.uniqueHandle(for: "!!!") == "operator")
        try library.save(persona("Senior Engineer", "senior-engineer"))
        try library.save(persona("Senior Engineer", "senior-engineer-2"))
        #expect(library.uniqueHandle(for: "senior engineer") == "senior-engineer-3")
        #expect(library.uniqueHandle(for: "Senior Engineer", excluding: "senior-engineer") == "senior-engineer")
    }
}
