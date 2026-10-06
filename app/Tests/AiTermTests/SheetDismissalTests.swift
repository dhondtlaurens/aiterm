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
    private func pressCommandReturn(on view: some View, width: CGFloat = Sheet.width, height: CGFloat = Sheet.height) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        // With a field holding the keyboard, as it does when the person has just typed a name.
        if let field = firstTextField(in: host) { window.makeFirstResponder(field) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { firstTextField(in: $0) }.first
    }

    /// `sheet` presented as the app presents its sheets, over a window of its own, with its first
    /// field holding the keyboard; then ⎋. Returns whether the sheet is still presented. The dismiss
    /// comes a main-actor turn after the event, which only an `await` lets run.
    private func pressEscape(presenting sheet: some View) async -> Bool {
        let presented = Presented()
        let host = NSHostingView(rootView: Color.clear.sheet(isPresented: Binding(get: { presented.isOn },
                                                                                   set: { presented.isOn = $0 })) { sheet })
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width + 100, height: Sheet.settingsHeight + 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        guard pumpRunLoop(describing: "the sheet to be presented", until: { window.attachedSheet != nil }),
              let sheetWindow = window.attachedSheet, let content = sheetWindow.contentView else { return true }
        settle(content)
        if let field = firstTextField(in: content) { sheetWindow.makeFirstResponder(field) }
        settle(content)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: sheetWindow.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
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
                                   initialName: "  Work  ", canSubmit: true, submit: { submitted.append($0) }))
        #expect(submitted == ["Work"])
    }

    @Test func settingsSavesAndDismissesAfterTheEvent() {
        var sizes: [InterfaceSize] = []
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: .scratch(), setMatchItermBackground: { _ in },
                                    setInterfaceSize: { sizes.append($0) }, initialTab: .interface)
        pressCommandReturn(on: settings, height: Sheet.settingsHeight)
        #expect(sizes.count == 1, "Save ran")
    }
}

/// Whether a test's sheet is presented, which the sheet's own dismiss sets back.
@Observable private final class Presented {
    var isOn = true
}
