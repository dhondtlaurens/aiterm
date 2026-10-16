import Foundation
import Observation
import AiTermCore

/// A second opinion's source: an agent and one of its models, labelled as the sheet's `Select` shows
/// it — "Codex · GPT-6-Astra".
struct SecondOpinionChoice: Hashable {
    let agent: AgentKind
    let model: AgentModel
    var label: String { "\(SidebarModel.agentName(agent)) · \(model.label)" }
}

/// The persona editor's text: the persona, then — once you have kept any — its lessons under their own
/// heading, as the operator's file holds them, so a lesson is read and edited where it was added (§4.5).
enum PersonaText {
    static let lessonsHeading = "## Lessons"

    static func join(persona: String, lessons: [String]) -> String {
        guard !lessons.isEmpty else { return persona }
        return persona + "\n\n" + lessonsHeading + "\n\n" + lessons.map { "- " + $0 }.joined(separator: "\n")
    }

    /// The persona above a `## Lessons` line, and the bullets below it; without that line, all of it is
    /// the persona.
    static func split(_ text: String) -> (persona: String, lessons: [String]) {
        let lines = text.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == lessonsHeading }) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let persona = lines[..<heading].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let lessons = lines[(heading + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (persona, lessons)
    }
}

/// The operator sheet's state: New Operator… (`editing` nil) and Edit Operator… alike. Built once by
/// `SheetCoordinator`, its catalogues read before it opens, as New Task's draft is — SwiftUI re-creates
/// a sheet's root on every change of the presenting view.
@MainActor
@Observable
final class OperatorSheetModel: Identifiable {
    let id = UUID()
    let editing: OperatorPersona?
    /// The models the operator can think with: Claude's, the one lead CLI in v1 (spec §3).
    let claudeModels: [AgentModel]
    /// Where a second opinion can come from: Codex's models, then Claude's.
    let secondOpinionChoices: [SecondOpinionChoice]

    var name: String
    var personaText: String
    var model: String
    var effort: String?
    var level: SecondOpinionLevel
    var secondOpinion: SecondOpinionChoice
    var secondOpinionEffort: String?
    var autonomy: Autonomy
    /// Why the last save was refused, in the footer.
    var error: String? = nil

    @ObservationIgnored private let takenHandles: Set<String>
    @ObservationIgnored private let save: @MainActor (OperatorPersona) throws -> Void

    static let subtitle = "Who it is and how it works. What to do comes with each operation."
    static let personaHelp = "Its character and habits, in every operation. Lessons you keep are added here."
    /// The lead's default, then Codex's for a second opinion from another family (spec §4.4).
    static let defaultModel = "claude-opus-5-5", defaultSecondOpinion = "gpt-6-astra"

    init(editing: OperatorPersona?, claudeModels: [AgentModel], codexModels: [AgentModel], takenHandles: Set<String>,
         save: @escaping @MainActor (OperatorPersona) throws -> Void) {
        self.editing = editing
        self.takenHandles = takenHandles
        self.save = save
        // A model the catalogue no longer lists stays chosen, under its own id, rather than be swapped.
        var lead = claudeModels
        if let kept = editing?.model, !lead.contains(where: { $0.id == kept }) {
            lead.append(AgentModel(id: kept, label: kept, detail: nil, efforts: editing?.effort.map { [$0] } ?? [],
                                   defaultEffort: editing?.effort))
        }
        if lead.isEmpty {
            lead = [AgentModel(id: Self.defaultModel, label: "Opus 5.5", detail: nil, efforts: ["high"], defaultEffort: "high")]
        }
        self.claudeModels = lead
        var choices = codexModels.map { SecondOpinionChoice(agent: .codex, model: $0) }
            + claudeModels.map { SecondOpinionChoice(agent: .claude, model: $0) }
        if let kept = editing?.secondOpinion, !choices.contains(where: { $0.agent == kept.agent && $0.model.id == kept.model }) {
            choices.append(SecondOpinionChoice(agent: kept.agent, model: AgentModel(id: kept.model, label: kept.model, detail: nil,
                                                                                    efforts: kept.effort.map { [$0] } ?? [],
                                                                                    defaultEffort: kept.effort)))
        }
        if choices.isEmpty {
            choices = [SecondOpinionChoice(agent: .codex, model: AgentModel(id: Self.defaultSecondOpinion, label: "GPT-6-Astra",
                                                                            detail: nil, efforts: ["medium"], defaultEffort: "medium"))]
        }
        secondOpinionChoices = choices

        name = editing?.name ?? ""
        personaText = editing.map { PersonaText.join(persona: $0.persona, lessons: $0.lessons) } ?? ""
        let leadModel = editing.flatMap { e in lead.first { $0.id == e.model } }
            ?? lead.first { $0.id == Self.defaultModel } ?? lead[0]
        model = leadModel.id
        effort = editing?.effort ?? leadModel.defaultEffort
        level = editing?.secondOpinion.level ?? .healthyDoubt
        let choice = editing.flatMap { e in choices.first { $0.agent == e.secondOpinion.agent && $0.model.id == e.secondOpinion.model } }
            ?? choices.first { $0.agent == .codex && $0.model.id == Self.defaultSecondOpinion } ?? choices[0]
        secondOpinion = choice
        secondOpinionEffort = editing?.secondOpinion.effort
            ?? (choice.model.efforts.contains("medium") ? "medium" : choice.model.defaultEffort)
        autonomy = editing?.autonomy ?? .routine
    }

    /// "New operator", or the operator's own name (the proposal: "titled with its name").
    var title: String { editing?.name ?? "New operator" }
    var primaryLabel: String { editing == nil ? "Create Operator" : "Save" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !trimmedName.isEmpty }

    var selectedModel: AgentModel { claudeModels.first { $0.id == model } ?? claudeModels[0] }
    var efforts: [String] { selectedModel.efforts }
    var secondOpinionEfforts: [String] { secondOpinion.model.efforts }
    /// At No self-doubt nothing is challenged, so the model that would challenge it is dimmed — and kept.
    var secondOpinionDimmed: Bool { level == .noSelfDoubt }

    /// Picks the lead's model, keeping its reasoning if the new model has it and taking its default if not.
    func selectModel(_ id: String) {
        model = id
        if !efforts.contains(effort ?? "") { effort = selectedModel.defaultEffort }
    }

    /// Picks the second opinion's source, keeping its reasoning if the new model has it.
    func selectSecondOpinion(_ choice: SecondOpinionChoice) {
        secondOpinion = choice
        if !secondOpinionEfforts.contains(secondOpinionEffort ?? "") { secondOpinionEffort = choice.model.defaultEffort }
    }

    /// The operator this sheet describes. A new one's handle — its file's name — comes from its name; an
    /// edited one keeps its own, and what the sheet does not show: `alwaysAsk` and the limits.
    func persona() -> OperatorPersona {
        let text = PersonaText.split(personaText)
        return OperatorPersona(
            name: trimmedName, handle: editing?.handle ?? Self.handle(for: trimmedName, taken: takenHandles),
            model: model, effort: efforts.isEmpty ? nil : effort,
            secondOpinion: SecondOpinion(level: level, agent: secondOpinion.agent, model: secondOpinion.model.id,
                                         effort: secondOpinionEfforts.isEmpty ? nil : secondOpinionEffort),
            autonomy: autonomy, alwaysAsk: editing?.alwaysAsk ?? [], limits: editing?.limits ?? OperatorLimits(),
            persona: text.persona, lessons: text.lessons)
    }

    /// Saves, and says whether the sheet may close; a refusal stays in the footer.
    func commit() -> Bool {
        guard canSave else { return false }
        do {
            try save(persona())
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// A name as a file name, by the library's own rule (`OperatorLibrary.handle(for:taken:)`): lower case,
    /// words joined by hyphens, `-2` and on past one taken, so it is the handle `uniqueHandle` would give.
    static func handle(for name: String, taken: Set<String>) -> String {
        OperatorLibrary.handle(for: name, taken: taken)
    }

    static func title(of level: SecondOpinionLevel) -> String {
        switch level {
        case .noSelfDoubt: "No self-doubt"
        case .healthyDoubt: "Healthy doubt"
        case .impostor: "Impostor"
        }
    }

    /// What the chosen stop does, under the segments — Healthy doubt's line is the proposal's.
    static func help(for level: SecondOpinionLevel) -> String {
        switch level {
        case .noSelfDoubt:
            "Nothing is challenged: its own model decides alone. The fastest."
        case .healthyDoubt:
            "Another model challenges its plan and its decisions — an answer it gives an agent, calling a task done — before they count. It revises or replies to each point."
        case .impostor:
            "As Healthy doubt, and every message it sends an agent too. Each challenge takes tens of seconds, so it is noticeably slower."
        }
    }

    static func title(of autonomy: Autonomy) -> String {
        switch autonomy {
        case .askFirst: "Ask first"
        case .routine: "Routine"
        case .trusted: "Trusted"
        case .handsOff: "Hands-off"
        }
    }

    /// What the chosen stop does (spec §4.1's table) — Routine's line is the proposal's.
    static func help(for autonomy: Autonomy) -> String {
        switch autonomy {
        case .askFirst:
            "Agents ask before each command. You approve each plan. It asks you anything its brief doesn’t answer, at once."
        case .routine:
            "Agents start in auto mode. You approve each plan. It asks you about scope and product choices and bundles other questions."
        case .trusted:
            "Agents start in auto mode. Plans start at once. It makes small product choices itself and logs them; questions come bundled when no other work can go on."
        case .handsOff:
            "Agents start in auto mode, and Codex never asks. Plans start at once. It asks only what must be asked, and tells you once the operation is blocked or done."
        }
    }
}
