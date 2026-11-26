import AppKit
import SwiftUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A folded OPERATOR or PROJECTS heading's chips are one button each, named for their own count; a folded project's
/// strip stays one label.
@MainActor @Suite(.serialized) struct StatusCountChipsAccessibilityTests {
    private let counts = [StatusCount(status: .working, count: 2), StatusCount(status: .needsInput, count: 1)]

    private func hosted(_ view: some View, until ready: ([NSObject]) -> Bool) -> (NSWindow, NSView, [NSObject]) {
        let host = testHost(AnyView(view), size: CGSize(width: 320, height: 40))
        let window = testWindow(hosting: host, styleMask: [])
        settle(host, describing: "the status chips' accessibility") { ready(AccessibilityTree.elements(host)) }
        return (window, host, AccessibilityTree.elements(host))
    }

    @Test func withAnActionEachChipIsAButtonNamedForItsCount() throws {
        var opened: [ChipTarget] = []
        try AccessibilityTree.with {
            let buttons = { (nodes: [NSObject]) in nodes.filter { AccessibilityTree.role(of: $0) == NSAccessibility.Role.button.rawValue } }
            let (window, host, nodes) = hosted(StatusCountChips(counts: counts, open: { opened.append($0) })) { buttons($0).count == 2 }
            defer { window.orderOut(nil) }
            let found = buttons(nodes)
            #expect(found.compactMap(AccessibilityTree.label(of:)) == ["2 working", "1 needs input"])
            #expect(found.compactMap(AccessibilityTree.help(of:)) == ["2 working", "1 needs input"])
            let needs = try #require(found.last)
            AccessibilityTree.press(needs)
            settle(host, describing: "the chip's press") { !opened.isEmpty }
            #expect(opened == [.status(.needsInput)], "pressing a chip opens at its status")
        }
    }

    /// In the folded heading itself, the chips stay buttons of their own beside the heading's words, which keep its
    /// name and fold.
    @Test func aFoldedSectionHeadingKeepsEachChipAButton() {
        AccessibilityTree.with {
            let fold = SectionFold(folds: true, folded: true, counts: counts)
            let label = SectionFoldLabel(title: "Projects", fold: fold, hovering: false, enabled: true, toggle: {}, open: { _ in })
            let buttons = { (nodes: [NSObject]) in nodes.filter { AccessibilityTree.role(of: $0) == NSAccessibility.Role.button.rawValue } }
            let chips = { (nodes: [NSObject]) in buttons(nodes).compactMap(AccessibilityTree.label(of:)).filter { $0 != "Projects" } }
            let (window, _, nodes) = hosted(label) { chips($0).count == 2 }
            defer { window.orderOut(nil) }
            #expect(chips(nodes) == ["2 working", "1 needs input"])
            #expect(nodes.contains { AccessibilityTree.label(of: $0) == "Projects" }, "the heading's words keep its name")
        }
    }

    /// The Operator's own chip leads and the finished chip ends, each a button named for what it counts.
    @Test func theOperatorChipAndTheFinishedChipAreButtonsOfTheirOwn() {
        AccessibilityTree.with {
            let chip = OperatorChip(mark: .status(.working), tasks: 3)
            let buttons = { (nodes: [NSObject]) in nodes.filter { AccessibilityTree.role(of: $0) == NSAccessibility.Role.button.rawValue } }
            let (window, _, nodes) = hosted(StatusCountChips(counts: [], lead: chip, finished: 1, open: { _ in })) { buttons($0).count == 2 }
            defer { window.orderOut(nil) }
            #expect(buttons(nodes).compactMap(AccessibilityTree.label(of:)) == ["3 tasks, working", "1 finished"])
        }
    }

    /// The OPERATOR heading's signals icon is a button that says its count in words, and its press opens the sheet.
    @Test func theSignalsIconIsAButtonNamedForItsCount() throws {
        var opened = 0
        try AccessibilityTree.with {
            let buttons = { (nodes: [NSObject]) in nodes.filter { AccessibilityTree.role(of: $0) == NSAccessibility.Role.button.rawValue } }
            let icon = SectionSignalsButton(section: .operator, count: 3, enabled: true) { opened += 1 }
            let (window, host, nodes) = hosted(icon) { buttons($0).count == 1 }
            defer { window.orderOut(nil) }
            let button = try #require(buttons(nodes).first)
            #expect(AccessibilityTree.label(of: button) == "3 Operator signals")
            AccessibilityTree.press(button)
            settle(host, describing: "the icon's press") { opened > 0 }
            #expect(opened == 1)
        }
    }

    @Test func withoutAnActionTheStripIsOneLabel() {
        AccessibilityTree.with {
            let label = "2 working, 1 needs input"
            let (window, _, nodes) = hosted(StatusCountChips(counts: counts)) { $0.contains { AccessibilityTree.label(of: $0) == label } }
            defer { window.orderOut(nil) }
            #expect(nodes.contains { AccessibilityTree.label(of: $0) == label })
            #expect(!nodes.contains { AccessibilityTree.role(of: $0) == NSAccessibility.Role.button.rawValue })
        }
    }
}
