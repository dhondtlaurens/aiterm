import AppKit
import Observation
import SwiftUI
import AiTermUI
import Testing
@testable import AiTerm
@testable import AiTermTestSupport

/// The stepped sheets' frame, driven over a fake sheet of three steps in a window, by the buttons and
/// keys a person uses: Cancel on every step and Back from the second, Continue until the create, ⌘↩
/// only while the step can advance, nothing but an open list's closing while a create runs, and a
/// background click closing the step's list.
@MainActor
@Suite(.serialized) struct SteppedSheetTests {
    @Test func onlyCompletedStepsCanBeClickedOrReachedByTheirNumber() {
        #expect(SheetStepper.canNavigate(from: 3, to: 1, count: 4))
        #expect(SheetStepper.canNavigate(from: 3, to: 2, count: 4))
        #expect(!SheetStepper.canNavigate(from: 3, to: 4, count: 4))
        #expect(!SheetStepper.canNavigate(from: 3, to: 0, count: 4))
    }

    @Test func cancelIsOnEveryStepBackFromTheSecondAndThePrimaryCreatesOnTheLast() throws {
        let h = Harness()
        defer { h.close() }
        var seen: [[String]] = []
        for step in 1...3 {
            h.sheet.step = step
            h.settle()
            seen.append(h.buttons().filter { ["Cancel", "Back", "Continue", "Make It"].contains($0) })
        }
        #expect(seen == [["Cancel", "Continue"], ["Cancel", "Back", "Continue"], ["Cancel", "Back", "Make It"]])
    }

    @Test func clickingBackGoesOneStepBack() throws {
        let h = Harness(step: 3)
        defer { h.close() }
        try h.press("Back")
        #expect(h.sheet.step == 2)
        try h.press("Back")
        #expect(h.sheet.step == 1)
    }

    @Test func commandReturnDoesNothingWhileTheStepCannotAdvance() {
        let h = Harness()
        defer { h.close() }
        h.sheet.canAdvance = false
        h.settle()
        h.key("\r", code: 36, [.command])
        #expect(h.sheet.step == 1)
        h.sheet.canAdvance = true
        h.settle()
        h.key("\r", code: 36, [.command])
        #expect(h.sheet.step == 2)
    }

    @Test func aDisabledStepSaysWhyOnlyWhileNoCreateRuns() {
        let h = Harness()
        defer { h.close() }
        h.sheet.whyNot = "Add an agent."
        h.sheet.canAdvance = false
        h.settle()
        #expect(h.texts().contains("Add an agent."))
        h.sheet.canAdvance = true
        h.settle()
        #expect(!h.texts().contains("Add an agent."))
        h.sheet.canAdvance = false
        h.sheet.creating = true
        h.settle()
        #expect(!h.texts().contains("Add an agent."))
    }

    /// Leaving a step closes its lists, every one of them.
    @Test func continuingClosesTheStepsLists() {
        let h = Harness()
        defer { h.close() }
        h.sheet.open = [2, 0, 0]
        h.key("\r", code: 36, [.command])
        #expect(h.sheet.step == 2 && h.sheet.open == [0, 0, 0])
    }

    /// While a create runs nothing moves the sheet: ⎋ only closes an open list, and Cancel, Back and
    /// ⌘1 are refused. Presented, so a dismiss would show.
    @Test func whileACreateRunsOnlyAnOpenListCloses() async throws {
        let h = Harness(step: 3, presented: true)
        defer { h.close() }
        h.sheet.creating = true
        h.sheet.open = [0, 0, 1]
        h.settle()
        h.key("\u{1b}", code: 53)
        #expect(h.sheet.open == [0, 0, 0], "⎋ still closes the list")
        h.key("\u{1b}", code: 53)
        await h.pause()
        #expect(h.isPresented, "⎋ with none open does not cancel")
        try h.press("Cancel")
        await h.pause()
        #expect(h.isPresented, "Cancel is refused")
        try h.press("Back")
        #expect(h.sheet.step == 3, "Back is refused")
        h.key("1", code: 18, [.command])
        #expect(h.sheet.step == 3, "⌘1 is refused")
    }

    @Test func aCreateThatFailsKeepsTheLastStep() async {
        let h = Harness(step: 3, presented: true)
        defer { h.close() }
        h.key("\r", code: 36, [.command])
        await eventually { h.sheet.creates == 1 }
        await h.pause()
        #expect(h.isPresented && h.sheet.step == 3)
    }

    @Test func aCreateThatSucceedsClosesTheSheet() async {
        let h = Harness(step: 3, presented: true)
        defer { h.close() }
        h.sheet.createSucceeds = true
        h.key("\r", code: 36, [.command])
        await eventually(describing: "the sheet to close") { !h.isPresented }
        #expect(h.sheet.creates == 1)
    }

    @Test func aBackgroundClickClosesTheCurrentStepsList() throws {
        let h = Harness(step: 2)
        defer { h.close() }
        h.sheet.open = [1, 1, 0]
        h.settle()
        try h.clickBackground()
        #expect(h.sheet.open == [1, 0, 0], "the second step's list, not the first's")
    }
}

/// Three steps whose lists are counted, and a create that answers `createSucceeds`.
@MainActor @Observable private final class FakeSheet {
    var step = 1
    var canAdvance = true
    var whyNot: String?
    var creating = false
    var createSucceeds = false
    var creates = 0
    /// How many lists each step has open.
    var open = [0, 0, 0]

    func closeList(_ step: Int) -> Bool {
        guard open[step - 1] > 0 else { return false }
        open[step - 1] -= 1
        return true
    }

    func create() async -> Bool {
        creates += 1
        return createSucceeds
    }
}

private struct FakeSheetView: View {
    @Bindable var sheet: FakeSheet
    var body: some View {
        SteppedSheet(title: "Fake", height: Sheet.creationHeight,
                     steps: (1...3).map { number in
                         Step(name: "Step \(number)", canAdvance: sheet.canAdvance, whyNot: sheet.whyNot, closeList: { sheet.closeList(number) })
                     },
                     step: $sheet.step, createLabel: "Make It", creating: sheet.creating, create: sheet.create) {
            Text("Content of step \(sheet.step)")
        } notices: {
            EmptyView()
        } closing: {
            Text("What it makes")
        }
    }
}

/// The fake sheet in a window of its own, or presented over one as the app presents its sheets.
@MainActor private final class Harness {
    let sheet: FakeSheet
    private let presented: Presented
    private let window: NSWindow
    private let content: NSView
    private let sheetWindow: NSWindow

    init(step: Int = 1, presented isPresented: Bool = false) {
        let sheet = FakeSheet(), presented = Presented()
        sheet.step = step
        let view = FakeSheetView(sheet: sheet)
        if isPresented {
            let host = NSHostingView(rootView: Color.clear.sheet(isPresented: Binding(get: { presented.isOn }, set: { presented.isOn = $0 })) { view })
            host.frame = NSRect(x: 0, y: 0, width: Sheet.width + 100, height: Sheet.settingsHeight + 100)
            let window = testWindow(hosting: host, styleMask: [.titled])
            pumpRunLoop(describing: "the sheet to be presented") { window.attachedSheet != nil }
            self.window = window
            sheetWindow = window.attachedSheet ?? window
            content = sheetWindow.contentView ?? host
        } else {
            let host = testHost(view, size: CGSize(width: Sheet.width, height: Sheet.creationHeight))
            window = testWindow(hosting: host, styleMask: [])
            sheetWindow = window
            content = host
        }
        self.sheet = sheet; self.presented = presented
        content.layoutSubtreeIfNeeded()
        settle()
    }

    var isPresented: Bool { presented.isOn }

    func close() { window.orderOut(nil) }

    func settle() { AiTermTestSupport.settle(content) }

    /// A main-actor turn or two, so a dismiss sent after an event would have landed.
    func pause() async {
        for _ in 0..<5 {
            await Task.yield()
            settle()
        }
    }

    func key(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        let event = keyDown(characters, code: code, modifiers: modifiers, in: sheetWindow)!
        _ = sheetWindow.performKeyEquivalent(with: event)
        settle()
    }

    /// The labels of the sheet's buttons, as AppKit's accessibility tree reads them.
    func buttons() -> [String] {
        withAccessibilityTree { buttonNodes().compactMap { Self.value(.description, getter: "accessibilityLabel", of: $0) as? String } }
    }

    func texts() -> [String] {
        withAccessibilityTree {
            Self.elements(content).compactMap { node in
                guard Self.value(.role, getter: "accessibilityRole", of: node) as? String == NSAccessibility.Role.staticText.rawValue else { return nil }
                return Self.value(.value, getter: "accessibilityValue", of: node) as? String
            }
        }
    }

    /// The button labelled `label`, pressed as VoiceOver or a click would.
    func press(_ label: String) throws {
        try withAccessibilityTree {
            let node = try #require(buttonNodes().first { Self.value(.description, getter: "accessibilityLabel", of: $0) as? String == label })
            _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
        }
        settle()
    }

    /// A click on the sheet's ground above its title, where no control is.
    func clickBackground() throws {
        let point = NSPoint(x: content.bounds.midX, y: content.isFlipped ? 4 : content.bounds.maxY - 4)
        let location = content.convert(point, to: nil)
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: sheetWindow.windowNumber, context: nil, eventNumber: 1,
                                                        clickCount: 1, pressure: pressure))
            sheetWindow.sendEvent(event)
        }
        settle()
    }

    private func buttonNodes() -> [NSObject] {
        Self.elements(content).filter {
            Self.value(.role, getter: "accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue
        }
    }

    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// Enhanced UI is an application attribute: on for one read, and put back after it.
    private func withAccessibilityTree<T>(_ body: () throws -> T) rethrows -> T {
        let app = NSApplication.shared
        let previous = app.accessibilityAttributeValue(Self.enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        defer { app.accessibilitySetValue(previous, forAttribute: Self.enhancedUI) }
        return try body()
    }

    /// SwiftUI's nodes answer the public ObjC methods, or the legacy attributes.
    private static func value(_ attribute: NSAccessibility.Attribute, getter: String, of node: NSObject) -> Any? {
        let selector = NSSelectorFromString(getter)
        if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() { return value }
        return node.accessibilityAttributeValue(attribute)
    }

    private static func elements(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 32, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = value(.children, getter: "accessibilityChildren", of: node) as? [NSObject] ?? []
            return [node] + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
}

/// Whether the fake sheet is presented, which its own dismiss sets back.
@Observable private final class Presented {
    var isOn = true
}
