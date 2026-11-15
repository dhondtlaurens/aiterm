import AppKit
import Testing
@testable import AiTerm
@testable import AiTermTestSupport

@Suite @MainActor struct ArchiveShortcutTests {
    func key(modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                         isARepeat: false, keyCode: 0)!
    }
    @Test func commandASelectsAllInAnEditableTextViewAndOpensArchiveElsewhere() {
        let editor = NSTextView(); editor.string = "The complete prompt"
        var opened = 0
        #expect(ArchiveShortcut.perform(key(), firstResponder: editor, openArchive: { opened += 1 }))
        #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
        #expect(opened == 0)
        #expect(ArchiveShortcut.perform(key(), firstResponder: nil, openArchive: { opened += 1 }))
        #expect(opened == 1)
        #expect(!ArchiveShortcut.perform(key(modifiers: [.command, .shift]), firstResponder: nil, openArchive: { opened += 1 }))
        #expect(opened == 1)
    }
}
