import Foundation
import Testing
@testable import AiTerm

/// Answers the app's modal questions from a script, by button title — or by key: "↩" presses the
/// default button and "⎋" the one the alert gives ⎋ (`AlertPrompt.escapeButton`) — and keeps what
/// was asked.
/// An unexpected question, or an answer the question does not offer, is recorded as an issue and
/// answered with its safe button — the one ⎋ answers, else its last — so a test fails rather than hangs.
@MainActor
final class ScriptedPrompter: Prompter {
    private var answers: [String]
    var checksTheCheckbox = false
    /// Runs while a question is on screen, before it is answered. `NSAlert.runModal` drains the main
    /// queue, so anything the app does can happen during a prompt; this is how a test makes it.
    var whileAsking: ((AlertPrompt) -> Void)?
    var folder: URL?
    private(set) var asked: [AlertPrompt] = []

    init(answering answers: String...) { self.answers = answers }
    init(answering answers: [String]) { self.answers = answers }

    func ask(_ prompt: AlertPrompt) -> AlertAnswer {
        asked.append(prompt)
        whileAsking?(prompt)
        let fallback = AlertAnswer(button: prompt.escapeButton ?? prompt.buttons.count - 1)
        guard !answers.isEmpty else {
            Issue.record("Unexpected prompt: \(prompt.message)")
            return fallback
        }
        let title = answers.removeFirst()
        if title == "↩" { return AlertAnswer(button: 0, checked: checksTheCheckbox) }
        if title == "⎋" {
            guard let escape = prompt.escapeButton else {
                Issue.record("“\(prompt.message)” gives ⎋ to no button: \(prompt.buttons)")
                return fallback
            }
            return AlertAnswer(button: escape)
        }
        guard let index = prompt.buttons.firstIndex(of: title), !prompt.unavailable.contains(title) else {
            Issue.record("“\(prompt.message)” offers no available \(title) button: \(prompt.buttons)")
            return fallback
        }
        return AlertAnswer(button: index, checked: checksTheCheckbox)
    }

    /// The prompts of the folder choosers the app opened.
    private(set) var folderPrompts: [String] = []

    func chooseFolder(prompt: String) -> URL? { folderPrompts.append(prompt); return folder }
}
