import AppKit
import SwiftUI
import AiTermUI
import AiTermCore
import Testing
import AiTermTestSupport
@testable import AiTerm

/// `ModelReasoningFields` labels its two `Select`s by default; unlabelled, as New Broadcast's Agents rows have them under
/// one row of column labels, it is the pop-ups alone, a control tall.
@MainActor
struct ModelReasoningFieldsTests {
    private static let opus = AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "high"], defaultEffort: "high")

    @Test(arguments: [true, false]) func unlabelledItIsThePopUpsAlone(labelled: Bool) {
        let fields = ModelReasoningFields(models: [Self.opus], model: Self.opus.id, reasoning: .constant("high"), labelled: labelled,
                                          selectModel: { _ in })
        let host = testHost(fields.frame(width: 360), size: CGSize(width: 360, height: 80))
        settle(host)
        #expect(host.descendants(NSPopUpButton.self).count == 2)
        #expect((host.fittingSize.height == Size.control) == !labelled)
    }

    /// Unlabelled, a model with no reasoning levels keeps the Model column's width beside an empty Reasoning cell, so rows
    /// under one row of column labels stay aligned.
    @Test func unlabelledAModelWithoutReasoningKeepsItsColumn() throws {
        let plain = AgentModel(id: "plain", label: "Plain", detail: nil, efforts: [], defaultEffort: nil)
        let alone = popups(models: [plain]), beside = popups(models: [Self.opus])
        #expect(alone.count == 1 && beside.count == 2)
        #expect(alone.first?.frame == beside.first?.frame, "the Model popup where a model with reasoning has it")
    }

    private func popups(models: [AgentModel]) -> [NSPopUpButton] {
        let fields = ModelReasoningFields(models: models, model: models[0].id, reasoning: .constant(nil), labelled: false,
                                          selectModel: { _ in })
        let host = testHost(fields.frame(width: 360), size: CGSize(width: 360, height: 80))
        settle(host)
        return host.descendants(NSPopUpButton.self)
    }
}
