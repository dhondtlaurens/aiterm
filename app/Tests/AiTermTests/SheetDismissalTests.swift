import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm

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
