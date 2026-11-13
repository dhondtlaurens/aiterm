import AiTermTestSupport
import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

/// The house push button (`PushButtonStyle`) in each state of its matrix: secondary and primary at rest
/// and pressed, the disabled fade, the accent ground a primary declares for its keycaps, one height with
/// a field, and a native button's behaviour kept — its key equivalent, and nothing while disabled.
@MainActor
@Suite(.serialized) struct PushButtonStyleTests {
    /// Lighter than its ground at rest and a step lighter pressed, edged in the soft hairline; the
    /// primary is the accent, dimmed while pressed, with no edge.
    @Test func eachKindFillsAndEdgesForItsState() {
        #expect(PushButtonStyle.fill(.secondary, pressed: false) == Palette.button)
        #expect(PushButtonStyle.fill(.secondary, pressed: true) == Palette.controlActive)
        #expect(PushButtonStyle.fill(.primary, pressed: false) == Palette.accent)
        #expect(PushButtonStyle.fill(.primary, pressed: true) == Palette.accentPressed)
        #expect(PushButtonStyle.edge(.secondary) == Palette.border)
        #expect(PushButtonStyle.edge(.primary) == nil)
    }

    /// The secondary's label is the text ink in the body face; the primary's the accent's white, medium.
    @Test func eachKindInksItsLabel() {
        #expect(PushButtonStyle.ink(.secondary) == Palette.text)
        #expect(PushButtonStyle.ink(.primary) == Palette.onAccent)
        #expect(PushButtonStyle.font(.secondary) == Typography.body)
        #expect(PushButtonStyle.font(.primary) == Typography.bodyEmphasis)
        #expect(PushButtonStyle.opacity(enabled: true) == 1)
        #expect(PushButtonStyle.opacity(enabled: false) == Opacity.disabled)
    }

    /// A primary declares the accent for what it carries; a secondary leaves the ground it stands on.
    @Test func thePrimaryDeclaresTheAccentSurface() {
        let log = EnvironmentLog()
        let host = testHost(VStack {
            Button {} label: { EnvironmentReader(id: 0, log: log) }.buttonStyle(.push(.primary))
            Button {} label: { EnvironmentReader(id: 1, log: log) }.buttonStyle(.push(.secondary))
        }.surface(.sidebar), size: CGSize(width: 120, height: 80))
        host.layoutSubtreeIfNeeded()
        #expect(log.surface == [0: .accent, 1: .sidebar])
    }

    /// Keycaps on a primary ink themselves for the accent, with nothing said by the caller: drawn the same
    /// as caps told so by hand, and unlike caps held to the sheet.
    @Test func aKbdOnAPrimaryInksForTheAccent() throws {
        func render(_ kbd: some View) throws -> Data {
            let host = testHost(Button {} label: { kbd }.buttonStyle(.push(.primary)).padding(4),
                                size: CGSize(width: 80, height: 40), appearance: NSAppearance(named: .darkAqua))
            settle(host)
            return try pixels(in: host)
        }
        let plain = try render(Kbd("⌘", "↩"))
        #expect(plain == (try render(Kbd("⌘", "↩").surface(.accent))))
        #expect(plain != (try render(Kbd("⌘", "↩").surface(.sheet))), "the test must tell the inks apart")
    }

    /// Pressed is drawn: the secondary's fill lifts and the primary's accent dims.
    @Test(arguments: [PushButtonStyle.Kind.secondary, .primary])
    func aPressIsDrawn(kind: PushButtonStyle.Kind) throws {
        func render(pressed: Bool) throws -> Data {
            let host = testHost(PushButtonBody(kind: kind, pressed: pressed) { Text("Cancel") }.padding(4),
                                size: CGSize(width: 100, height: 40), appearance: NSAppearance(named: .darkAqua))
            settle(host)
            return try pixels(in: host)
        }
        #expect(try render(pressed: true) != render(pressed: false))
    }

    /// Disabled, the whole button fades to `Opacity.disabled`: its brightest ink, the label, dims with it.
    @Test(arguments: [PushButtonStyle.Kind.secondary, .primary])
    func aDisabledButtonFades(kind: PushButtonStyle.Kind) throws {
        func brightest(_ enabled: Bool) throws -> CGFloat {
            let pixel = try #require(brightestPixel(of: Button("Save") {}.buttonStyle(.push(kind)).disabled(!enabled)))
            return pixel.redComponent + pixel.greenComponent + pixel.blueComponent
        }
        let enabled = try brightest(true), disabled = try brightest(false)
        #expect(disabled < enabled * 0.6, "enabled \(enabled), disabled \(disabled)")
    }

    /// One shape with a field: `Size.control` tall at ×1, and scaled with the sidebar it sits in.
    @Test(arguments: InterfaceScale.all)
    func itIsAControlTall(scale: InterfaceScale) {
        let host = NSHostingView(rootView: Button("Add Project…") {}.buttonStyle(.push(.secondary)).interfaceScale(scale))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - scale(Size.control)) < 0.5)
    }

    /// Still a native button: its key equivalent fires it while it is enabled, and a disabled one takes
    /// neither the key nor the action.
    @Test func itKeepsItsKeyAndADisabledOneDoesNotFire() {
        final class Presses { var count = 0 }
        func pressCommandReturn(enabled: Bool) -> Int {
            let presses = Presses()
            let host = testHost(Button("Save") { presses.count += 1 }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.push(.primary))
                .disabled(!enabled), size: CGSize(width: 120, height: 40))
            let window = testWindow(hosting: host, styleMask: [])
            defer { window.orderOut(nil) }
            settle(host)
            if let event = keyDown("\r", code: 36, modifiers: [.command], in: window) {
                _ = window.performKeyEquivalent(with: event)
            }
            settle(host)
            return presses.count
        }
        #expect(pressCommandReturn(enabled: true) == 1)
        #expect(pressCommandReturn(enabled: false) == 0)
    }
}
