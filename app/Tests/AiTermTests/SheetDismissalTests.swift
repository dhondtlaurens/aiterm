import AppKit
import Observation
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Every sheet's primary action dismisses once its event is over, never inside it. Hosted in a plain
/// window — left to release itself on close, as `JiraProjectSheetTests`' windows are — a dismiss
/// inside the ⌘↩ event closes that window under the event and the process crashes. So each test
/// passing at all is the assertion; the submit is checked to show the press was real.
@MainActor
@Suite(.serialized) struct SheetDismissalTests {
    /// `view` in a window of its own, its first field holding the keyboard; then ⌘↩, and the run
    /// loop turned until `done` says the sheet's action ran.
    private func pressCommandReturn(on view: some View, width: CGFloat = Sheet.width, height: CGFloat = Sheet.height,
                                    until done: () -> Bool) {
        let host = testHost(view, size: CGSize(width: width, height: height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTextField.self) != nil || host.firstDescendant(NSSwitch.self) != nil }
        // With a field holding the keyboard, as it does when the person has just typed a name.
        if let field = host.firstDescendant(NSTextField.self) { window.makeFirstResponder(field) }
        let event = keyDown("\r", code: 36, modifiers: [.command], in: window)!
        _ = window.performKeyEquivalent(with: event)
        pumpRunLoop(describing: "the sheet's action to run", until: done)
    }

    /// `sheet` presented as the app presents its sheets, over a window of its own, with its first
    /// field holding the keyboard; then ⎋. Returns whether the sheet is still presented. The dismiss
    /// comes a main-actor turn after the event, which only an `await` lets run.
    private func pressEscape(presenting sheet: some View) async -> Bool {
        let presented = Presented()
        let host = NSHostingView(rootView: Color.clear.sheet(isPresented: Binding(get: { presented.isOn },
                                                                                   set: { presented.isOn = $0 })) { sheet })
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width + 100, height: Sheet.settingsHeight + 100)
        let window = testWindow(hosting: host, styleMask: [.titled])
        defer { window.orderOut(nil) }
        guard pumpRunLoop(describing: "the sheet to be presented", until: { window.attachedSheet != nil }),
              let sheetWindow = window.attachedSheet, let content = sheetWindow.contentView else { return true }
        settle(content)
        if let field = content.firstDescendant(NSTextField.self) { sheetWindow.makeFirstResponder(field) }
        settle(content)
        let event = keyDown("\u{1b}", code: 53, in: sheetWindow)!
        _ = sheetWindow.performKeyEquivalent(with: event)
        await eventually(describing: "the sheet to close") {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            return !presented.isOn
        }
        return presented.isOn
    }

    /// ⎋ in the name sheet, its field holding the keyboard, closes it without submitting.
    @Test func escapeClosesTheNameSheetWithoutSubmitting() async {
        var submitted: [String] = []
        let open = await pressEscape(presenting: NameSheet(title: "Rename", subtitle: "Renames it.", fieldLabel: "Name", placeholder: "Name",
                                                     confirmLabel: "Rename", initialName: "Work", canSubmit: true,
                                                     submit: { submitted.append($0) }))
        #expect(!open)
        #expect(submitted.isEmpty)
    }

    /// ⎋ in Settings is its Cancel: the sheet closes, the size it opened on is put back, and
    /// nothing is saved.
    @Test func escapeCancelsSettings() async {
        var sizes: [InterfaceSize] = [], backgrounds: [Bool] = []
        let preferences = InterfacePreferences.scratch()
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: preferences, setMatchItermBackground: { backgrounds.append($0) },
                                    setInterfaceSize: { sizes.append($0) }, initialTab: .integrations)
        let open = await pressEscape(presenting: settings)
        #expect(!open)
        #expect(sizes == [preferences.interfaceSize], "Cancel puts back the size Settings opened on")
        #expect(backgrounds.isEmpty, "nothing was saved")
    }

    @Test func nameSheetSubmitsAndDismissesAfterTheEvent() {
        var submitted: [String] = []
        pressCommandReturn(on: NameSheet(title: "Rename", subtitle: "Renames it.", fieldLabel: "Name", placeholder: "Name", confirmLabel: "Rename",
                                   initialName: "  Work  ", canSubmit: true, submit: { submitted.append($0) })) { !submitted.isEmpty }
        #expect(submitted == ["Work"])
    }

    /// A plain ↩ in Rename's field presses Rename, as ⌘↩ does: one question, one key.
    @Test func plainReturnInANameSheetSubmitsAndDismissesAfterTheEvent() throws {
        var submitted: [String] = []
        let host = testHost(NameSheet(title: "Rename", subtitle: "Renames it.", fieldLabel: "Name", placeholder: "Name", confirmLabel: "Rename",
                                      initialName: "  Work  ", canSubmit: true, submit: { submitted.append($0) }),
                            size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTextField.self) != nil }
        let field = try #require(host.firstDescendant(NSTextField.self))
        #expect(window.makeFirstResponder(field))
        settle(host)
        window.sendEvent(keyDown("\r", code: 36, in: window)!)
        pumpRunLoop(describing: "the rename to run") { !submitted.isEmpty }
        #expect(submitted == ["Work"])
    }

    /// A name sheet that cannot submit leaves a plain ↩ to its field.
    @Test func plainReturnInANameSheetThatCannotSubmitDoesNothing() throws {
        var submitted: [String] = []
        let host = testHost(NameSheet(title: "Rename", fieldLabel: "Name", placeholder: "Name", confirmLabel: "Rename",
                                      initialName: "Work", canSubmit: false, submit: { submitted.append($0) }),
                            size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTextField.self) != nil }
        let field = try #require(host.firstDescendant(NSTextField.self))
        #expect(window.makeFirstResponder(field))
        settle(host)
        window.sendEvent(keyDown("\r", code: 36, in: window)!)
        settle(host, for: 0.1)
        #expect(submitted.isEmpty)
    }

    /// ⎋ on New Task's second step, with no list open, closes the sheet rather than going back.
    @Test func escapeOnNewTasksSecondStepClosesTheSheet() async {
        let model = TaskCreationModel(project: .make(), draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "m", reasoning: nil),
                                      context: .scratch(git: NoPickerGit()), searchIssues: { _ in [] }, createTask: { _ in })
        model.draft.setTitle("Fix the login form")
        let open = await pressEscape(presenting: NewTaskSheet(model: model).seeded(step: 2))
        #expect(!open)
    }

    @Test func settingsSavesAndDismissesAfterTheEvent() {
        var sizes: [InterfaceSize] = []
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: .scratch(), setMatchItermBackground: { _ in },
                                    setInterfaceSize: { sizes.append($0) }, initialTab: .interface)
        pressCommandReturn(on: settings, height: Sheet.settingsHeight) { !sizes.isEmpty }
        #expect(sizes.count == 1, "Save ran")
    }
}

/// Whether a test's sheet is presented, which the sheet's own dismiss sets back.
@Observable private final class Presented {
    var isOn = true
}
