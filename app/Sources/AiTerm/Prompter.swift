import AppKit
import AiTermCore

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

extension AlertPrompt {
    @MainActor static func removeTask(_ task: TaskItem, detail: String) -> AlertPrompt {
        let offersBranch = offersBranchDeletion(for: task)
        return AlertPrompt(message: "Remove \(task.kindName.lowercased()) “\(task.title)”?", detail: detail,
                           buttons: ["Remove", "Cancel"],
                           checkbox: offersBranch ? "Delete local branch" : nil,
                           checkboxHelp: offersBranch ? task.branch : nil, defaultDeletes: true)
    }

    /// Whether the remove alert offers a "Delete local branch" checkbox. A review's branch is the merge request's,
    /// which the host deletes on merge, so it never does.
    ///
    /// This is the courtesy, not the guarantee: `TaskWorkflow.remove` refuses a review's branch deletion outright, so a
    /// caller that asks anyway still gets nothing. Hiding the checkbox here only keeps the alert from offering
    /// something that would be ignored.
    static func offersBranchDeletion(for task: TaskItem) -> Bool { task.kind != .review }

    /// The question before a branch with commits its base lacks is deleted, which deletes them too. Delete Branch is
    /// the red default; Keep Branch answers ⎋ and still removes the row.
    static func deleteUnmergedBranchQuestion(for task: TaskItem) -> AlertPrompt {
        let base = task.baseBranch.isEmpty ? "its base" : task.baseBranch
        return AlertPrompt(
            message: "Delete branch \(task.branch)?",
            detail: "It has commits that aren’t on \(base). Deleting the branch deletes them too.",
            buttons: ["Delete Branch", "Keep Branch"], defaultDeletes: true, escape: 1)
    }

    /// The question before a folder git no longer lists is deleted: it may hold files AiTerm did not make. Keep is the
    /// default and ⎋. One wording for Remove and Archive.
    static func unlistedFolderQuestion(for task: TaskItem) -> AlertPrompt {
        AlertPrompt(message: "Delete the unlisted folder for “\(task.title)”?",
                    detail: "Git no longer lists this folder as a worktree. It may contain files AiTerm did not create.\n\(task.worktreePath)",
                    buttons: ["Keep", "Delete Folder"], escape: 0)
    }

    /// The question before a worktree's uncommitted changes and untracked files are deleted. Keeping is the default,
    /// on ↩ and ⎋ both; deleting is the plain grey button beside it, never marked red: the red default is for a button
    /// ↩ can press.
    static func unsavedWorkQuestion(for task: TaskItem, archiving: Bool) -> AlertPrompt {
        AlertPrompt(
            message: "The worktree has uncommitted changes",
            detail: archiving ? "Archiving deletes its uncommitted changes and untracked files. The branch is kept."
                              : "Removing this worktree permanently deletes its uncommitted changes and untracked files.",
            buttons: [task.kind == .review ? "Keep Review" : "Keep Task",
                      archiving ? "Delete Changes and Archive" : "Delete Changes and Remove"], escape: 0)
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
/// inside a SwiftUI key handler either, where one comes up without its checkbox.
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
        // The checkbox is NSAlert's own suppression button, retitled: NSAlert lines it up with the
        // text, where an accessory view as narrow as its title comes up centred under it.
        if let checkbox = prompt.checkbox {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = checkbox
            alert.suppressionButton?.toolTip = prompt.checkboxHelp
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
                           checked: alert.showsSuppressionButton && alert.suppressionButton?.state == .on)
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
