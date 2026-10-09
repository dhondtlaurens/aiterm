import AppKit

/// One modal question: a message, the detail under it, its buttons and an optional checkbox. A
/// value, so a test can read what was asked and answer it without a window.
///
/// The detail says what happens, in a sentence or two, and leaves out what the message and the
/// clicked row already say: no paths, no branch names. A name the person may still want rides on
/// the checkbox's tooltip, `checkboxHelp`.
///
/// The first button is the one default: it answers ↩ and is drawn blue — or red, with
/// `defaultDeletes`, when it deletes files or commits. Every other button is the plain grey one; no
/// other button can be marked destructive, because nothing here says so. ⎋ answers `escapeButton`,
/// the safe choice, which may be the default itself (Keep Task, Cancel Quit).
struct AlertPrompt: Equatable {
    var message: String
    var detail = ""
    var buttons = ["OK"]
    /// Buttons shown but not clickable, such as Restore Backup when there is no usable backup.
    var unavailable: Set<String> = []
    var checkbox: String?
    /// The checkbox's tooltip: the branch "Delete local branch" deletes.
    var checkboxHelp: String?
    /// The default button deletes files or commits: Remove on a task, Delete Branch.
    var defaultDeletes = false
    /// The button ⎋ answers, when it is not the one titled Cancel or the only one.
    var escape: Int?

    /// Which button ⎋ answers: `escape`, else the one titled Cancel, else a lone button. `nil` leaves
    /// ⎋ unanswered — an alert with no safe choice.
    var escapeButton: Int? {
        escape ?? buttons.firstIndex(of: "Cancel") ?? (buttons.count == 1 ? 0 : nil)
    }
}

struct AlertAnswer: Equatable {
    /// Index into `AlertPrompt.buttons`.
    var button: Int
    var checked = false
    /// Whether the default — first — button was chosen: Remove, Import, Retry.
    var confirmed: Bool { button == 0 }
}

/// Where the app's modal questions go. `ModalPrompter` shows them; tests answer them from a script,
/// which keeps every controller test in the ordinary test pass instead of driving real alerts.
///
/// A question is an `await`. While it is up, anything else the app does can run — a snapshot, a
/// window closing, another Remove — and it runs there, at a suspension Swift marks and the caller
/// re-checks after, never in the middle of the caller's own code as a modal run loop nested under
/// it would. The alert itself comes up on a later turn of the main run loop, so it is never run
/// inside a SwiftUI key handler either, where one comes up without its accessory view.
@MainActor
protocol Prompter {
    @discardableResult func ask(_ prompt: AlertPrompt) async -> AlertAnswer
    /// The same question, answered before this returns: the alert runs modally right here, and
    /// whatever was queued runs while it is up. Only for an AppKit callback that must answer before
    /// it returns — the launch's unreadable workspace and the last update's failure, the quit's
    /// unsaved changes — and never from a key handler.
    @discardableResult func askBlocking(_ prompt: AlertPrompt) -> AlertAnswer
    /// A folder the person picked, or `nil` when they cancelled.
    func chooseFolder(prompt: String) async -> URL?
}

@MainActor
struct ModalPrompter: Prompter {
    /// Nonisolated so it can be a default argument; the alerts themselves run on the main actor.
    nonisolated init() {}

    /// ⎋ as `NSButton.keyEquivalent` spells it.
    static let escapeKey = "\u{1b}"

    /// The alert `prompt` describes, not yet shown. NSAlert gives the first button ↩ and a button
    /// titled Cancel ⎋ by itself; any other safe button is handed ⎋ here. A safe button that is also
    /// the default keeps ↩ — a button holds one key — and `ask` answers ⎋ for it instead.
    static func alert(for prompt: AlertPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.detail
        for title in prompt.buttons {
            alert.addButton(withTitle: title).isEnabled = !prompt.unavailable.contains(title)
        }
        alert.buttons.first?.hasDestructiveAction = prompt.defaultDeletes
        if let escape = prompt.escapeButton, escape > 0, alert.buttons.indices.contains(escape) {
            alert.buttons[escape].keyEquivalent = escapeKey
        }
        alert.accessoryView = prompt.checkbox.map {
            let checkbox = NSButton(checkboxWithTitle: $0, target: nil, action: nil)
            checkbox.toolTip = prompt.checkboxHelp
            return checkbox
        }
        return alert
    }

    /// `askBlocking`, on the next turn of the main run loop rather than under the caller.
    func ask(_ prompt: AlertPrompt) async -> AlertAnswer {
        await withCheckedContinuation { answered in
            RunLoop.main.perform { MainActor.assumeIsolated { answered.resume(returning: askBlocking(prompt)) } }
        }
    }

    func askBlocking(_ prompt: AlertPrompt) -> AlertAnswer {
        let alert = Self.alert(for: prompt)
        // ⎋ for a safe default, which is holding ↩: pressed through the button, as a click would be.
        let monitor = prompt.escapeButton == 0 ? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.charactersIgnoringModifiers == Self.escapeKey,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            alert.buttons.first?.performClick(nil)
            return nil
        } : nil
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let response = alert.runModal()
        return AlertAnswer(button: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
                           checked: (alert.accessoryView as? NSButton)?.state == .on)
    }

    /// Run modally, as `ask`'s alert is, on a later turn of the main run loop.
    func chooseFolder(prompt: String) async -> URL? {
        await withCheckedContinuation { chosen in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    panel.prompt = prompt
                    chosen.resume(returning: panel.runModal() == .OK ? panel.url : nil)
                }
            }
        }
    }
}
