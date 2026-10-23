import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Settings › Operator's Instructions is the last field of a scrolling sheet: its `/` popup opens
/// above the editor, where there is room, and lies wholly inside what the sheet shows.
@MainActor
@Suite(.serialized, .enabled(if: !LoginSession.isLocked, "a window cannot become key while the screen is locked"))
struct OperatorInstructionsPopupTests {
    @Test func theOpenPopupLiesInsideTheSheet() throws {
        let skills = (1...12).map { AgentCompletion(name: "skill-\($0)", kind: .skill, detail: nil, source: .user) }
        let model = OperatorSettingsModel(load: { fatalError("handed in") }, save: { _ in })
        model.received(.init(profile: OperatorProfile(model: "claude-opus-5-5", reasoning: "high"),
                             models: [.claude: [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil,
                                                           efforts: ["high"], defaultEffort: "high")]],
                             agentDefaults: [:], skills: skills))
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: .scratch(), setMatchItermBackground: { _ in }, setInterfaceSize: { _ in },
                                    initialTab: .operator, testRecord: ServiceTestRecord(), operatorSettings: model)
        let host = testHost(settings, size: CGSize(width: Sheet.width, height: Sheet.settingsHeight))
        let window = testWindow(contentRect: host.frame, styleMask: [])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle(host) { textView(in: host) != nil }

        let editor = try #require(textView(in: host))
        let editorScroll = try #require(editor.enclosingScrollView)
        let sheetScroll = try #require(editorScroll.enclosingScrollView, "the tab scrolls in the sheet's scroll view")
        // Scrolled to the end, where Instructions sits as the sheet's last field.
        let document = try #require(sheetScroll.documentView)
        sheetScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - sheetScroll.contentView.bounds.height)))
        sheetScroll.reflectScrolledClipView(sheetScroll.contentView)
        settle(host)

        #expect(window.makeFirstResponder(editor))
        editor.insertText("/", replacementRange: editor.selectedRange())
        settle(host)
        #expect(model.completions.isOpen)
        #expect(model.completions.visible.count == 8)
        #expect(model.completions.opensAbove, "no room below the last field")

        // The popup, in window coordinates (y up): its top `anchor.y` below the editor's top.
        let field = editorScroll.convert(editorScroll.bounds, to: nil)
        let top = field.maxY - model.completions.anchor.y
        let bottom = top - CompletionPopup.height(rows: model.completions.visible.count)
        let visible = sheetScroll.contentView.convert(sheetScroll.contentView.bounds, to: nil)
        #expect(bottom >= visible.minY && top <= visible.maxY, "popup \(bottom)…\(top) inside \(visible.minY)…\(visible.maxY)")
        #expect(bottom >= field.maxY - PromptEditor.textInset.height, "above the caret's line, the editor's first, clear of its text")
    }

    /// ⎋ with the `/` popup open closes the popup and keeps the sheet and its edits; the next ⎋ is Cancel.
    @Test func escapeClosesTheOpenPopupBeforeSettingsCancels() throws {
        let skills = (1...3).map { AgentCompletion(name: "skill-\($0)", kind: .skill, detail: nil, source: .user) }
        let model = OperatorSettingsModel(load: { fatalError("handed in") }, save: { _ in })
        model.received(.init(profile: OperatorProfile(model: "claude-opus-5-5", reasoning: "high"),
                             models: [.claude: [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil,
                                                           efforts: ["high"], defaultEffort: "high")]],
                             agentDefaults: [:], skills: skills))
        var cancels = 0
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: .scratch(), setMatchItermBackground: { _ in },
                                    setInterfaceSize: { _ in cancels += 1 },
                                    initialTab: .operator, testRecord: ServiceTestRecord(), operatorSettings: model)
        let host = testHost(settings, size: CGSize(width: Sheet.width, height: Sheet.settingsHeight))
        let window = testWindow(contentRect: host.frame, styleMask: [])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle(host) { textView(in: host) != nil }
        let editor = try #require(textView(in: host))
        #expect(window.makeFirstResponder(editor))
        editor.insertText("/", replacementRange: editor.selectedRange())
        settle(host)
        #expect(model.completions.isOpen)

        let escape = keyDown("\u{1b}", code: 53, in: window)!
        _ = window.performKeyEquivalent(with: escape)
        settle(host)
        #expect(!model.completions.isOpen, "the first ⎋ closes the popup")
        #expect(cancels == 0, "and Settings' Cancel has not run")
    }

    private func textView(in view: NSView) -> PromptTextView? {
        if let text = view as? PromptTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
