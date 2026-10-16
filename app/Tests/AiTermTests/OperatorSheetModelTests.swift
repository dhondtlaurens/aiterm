import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator sheet as a model: what it opens with, what each stop of its two stepped settings
/// says, and the operator it saves — new or edited (spec §10.5, proposal step 2).
@MainActor
struct OperatorSheetModelTests {
    static let opus = AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")
    static let sonnet = AgentModel(id: "claude-sonnet-5", label: "Sonnet 5", detail: nil, efforts: ["low", "medium"], defaultEffort: "medium")
    static let astra = AgentModel(id: "gpt-6-astra", label: "GPT-6-Astra", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")

    private func model(editing: OperatorPersona? = nil, taken: Set<String> = [],
                       save: @escaping @MainActor (OperatorPersona) throws -> Void = { _ in }) -> OperatorSheetModel {
        OperatorSheetModel(editing: editing, claudeModels: [Self.sonnet, Self.opus], codexModels: [Self.astra],
                           takenHandles: taken, save: save)
    }

    @Test func aNewOperatorOpensOnTheDesignsDefaults() {
        let sheet = model()
        #expect(sheet.title == "New operator")
        #expect(OperatorSheetModel.subtitle == "Who it is and how it works. What to do comes with each operation.")
        #expect(sheet.primaryLabel == "Create Operator")
        #expect(sheet.model == "claude-opus-5-5" && sheet.effort == "high")
        #expect(sheet.level == .healthyDoubt && sheet.autonomy == .routine)
        #expect(sheet.secondOpinion.label == "Codex · GPT-6-Astra")
        #expect(sheet.secondOpinionEffort == "medium", "another family's model, at medium (spec §4.4)")
        #expect(!sheet.canSave, "it needs a name")
        sheet.name = "  Senior engineer "
        #expect(sheet.canSave)
    }

    @Test func eachStopSaysWhatItDoes() {
        #expect(SecondOpinionLevel.allCases.map(OperatorSheetModel.title(of:)) == ["No self-doubt", "Healthy doubt", "Impostor"])
        #expect(Autonomy.allCases.map(OperatorSheetModel.title(of:)) == ["Ask first", "Routine", "Trusted", "Hands-off"])
        #expect(OperatorSheetModel.help(for: SecondOpinionLevel.healthyDoubt)
                == "Another model challenges its plan and its decisions — an answer it gives an agent, calling a task done — before they count. It revises or replies to each point.")
        #expect(OperatorSheetModel.help(for: Autonomy.routine)
                == "Agents start in auto mode. You approve each plan. It asks you about scope and product choices and bundles other questions.")
        #expect(OperatorSheetModel.help(for: SecondOpinionLevel.impostor).contains("noticeably slower"), "each stop says what it costs")
        let lines = SecondOpinionLevel.allCases.map(OperatorSheetModel.help(for:)) + Autonomy.allCases.map(OperatorSheetModel.help(for:))
        #expect(Set(lines).count == lines.count && lines.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func noSelfDoubtDimsTheModelThatWouldGiveIt() {
        let sheet = model()
        #expect(!sheet.secondOpinionDimmed)
        sheet.level = .noSelfDoubt
        #expect(sheet.secondOpinionDimmed)
    }

    @Test func aModelsReasoningFollowsTheModel() {
        let sheet = model()
        sheet.selectModel(Self.sonnet.id)
        #expect(sheet.efforts == ["low", "medium"])
        #expect(sheet.effort == "medium", "high is not Sonnet's, so its default")
    }

    @Test func savingANewOperatorNamesItsFileFromItsName() throws {
        var saved: [OperatorPersona] = []
        let sheet = model(taken: ["senior-engineer"]) { saved.append($0) }
        sheet.name = "Senior engineer"
        sheet.personaText = "You keep changes small.\n\n## Lessons\n\n- Ask before adding a field a ticket doesn’t mention."
        sheet.autonomy = .trusted
        #expect(sheet.commit())
        let persona = try #require(saved.first)
        #expect(persona.handle == "senior-engineer-2", "taken handles are not reused")
        #expect(persona.persona == "You keep changes small.")
        #expect(persona.lessons == ["Ask before adding a field a ticket doesn’t mention."])
        #expect(persona.secondOpinion == SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium"))
        #expect(persona.autonomy == .trusted && persona.limits == OperatorLimits())
    }

    @Test func editingKeepsTheFileAndWhatTheSheetDoesNotShow() throws {
        var existing = OperatorUIFixtures.persona("Senior engineer", handle: "senior", lessons: ["Keep diffs small."])
        existing.alwaysAsk = ["database migrations"]
        var saved: OperatorPersona?
        let sheet = model(editing: existing) { saved = $0 }
        #expect(sheet.title == "Senior engineer")
        #expect(sheet.primaryLabel == "Save")
        #expect(sheet.personaText.hasSuffix("## Lessons\n\n- Keep diffs small."), "kept lessons are read and edited in the persona")
        sheet.name = "Staff engineer"
        #expect(sheet.commit())
        #expect(saved?.handle == "senior" && saved?.name == "Staff engineer")
        #expect(saved?.alwaysAsk == ["database migrations"] && saved?.lessons == ["Keep diffs small."])
    }

    @Test func aRefusedSaveKeepsTheSheetOpenSayingWhy() {
        struct Refused: LocalizedError { var errorDescription: String? { "The operators folder is read-only." } }
        let sheet = model { _ in throw Refused() }
        sheet.name = "Senior engineer"
        #expect(!sheet.commit())
        #expect(sheet.error == "The operators folder is read-only.")
    }

    @Test func thePersonaTextRoundTripsItsLessons() {
        let text = PersonaText.join(persona: "Be brief.", lessons: ["One.", "Two."])
        #expect(text == "Be brief.\n\n## Lessons\n\n- One.\n- Two.")
        #expect(PersonaText.split(text) == ("Be brief.", ["One.", "Two."]))
        #expect(PersonaText.split("Just a persona.\n") == ("Just a persona.", []))
        #expect(PersonaText.join(persona: "Be brief.", lessons: []) == "Be brief.")
    }

    @Test func aHandleIsTheNameInLowerCaseWords() {
        #expect(OperatorSheetModel.handle(for: "Senior engineer", taken: []) == "senior-engineer")
        #expect(OperatorSheetModel.handle(for: "  QA / Release!! ", taken: []) == "qa-release")
        #expect(OperatorSheetModel.handle(for: "???", taken: []) == "operator")
        #expect(OperatorSheetModel.handle(for: "QA", taken: ["qa", "qa-2"]) == "qa-3")
    }

    // -- agreeing with the library (D15) ---------------------------------------------------
    // The sheet names a new operator's file the way `OperatorLibrary.uniqueHandle` does, and is told
    // the names taken the way the library counts them: by the files in its folder.

    @Test func aHandleIsChosenAsTheLibraryChoosesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-sheet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = OperatorLibrary(directory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // One a persona's file and one that is not an operator at all: both take their names.
        try library.save(OperatorUIFixtures.persona("Senior engineer", handle: "senior-engineer"))
        try Data("not an operator".utf8).write(to: root.appendingPathComponent("Senior-Engineer-2.md"))
        let taken = library.takenHandles()
        #expect(taken == ["senior-engineer", "senior-engineer-2"], "by the file’s name, lower case, readable or not")
        let long = String(repeating: "word ", count: 20)
        for name in ["Senior engineer", "senior ENGINEER", "Café — Ops!", "???", "QA", long, "  -- "] {
            #expect(OperatorSheetModel.handle(for: name, taken: taken) == library.uniqueHandle(for: name), "\(name)")
        }
        #expect(OperatorSheetModel.handle(for: "Café — Ops!", taken: []) == "cafe-ops")
        #expect(OperatorSheetModel.handle(for: long, taken: []).count <= 48)
        #expect(OperatorSheetModel.handle(for: "senior engineer", taken: taken) == "senior-engineer-3")
    }

    @Test func aTakenHandleIsComparedWithoutCase() {
        #expect(OperatorSheetModel.handle(for: "QA", taken: ["QA"]) == "qa-2", "the Mac’s file system does not tell them apart")
    }
}
