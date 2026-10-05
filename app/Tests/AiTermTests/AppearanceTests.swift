import AppKit
import SwiftUI
import Testing
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite(.serialized) struct AppearanceTests {
    @Test func darkAppearanceDiscardsTheRetiredPreference() throws {
        let defaults = ScratchDefaults.make()
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        defaults.set("obsolete-choice", forKey: "appearance")
        defaults.set(true, forKey: "matchItermBackground")
        NSApplication.shared.appearance = nil

        Appearance.apply(defaults: defaults)

        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        #expect(defaults.object(forKey: "appearance") == nil)
        #expect(defaults.bool(forKey: "matchItermBackground"))

        // A fresh install and subsequent launches use the same fixed appearance.
        Appearance.apply(defaults: defaults)
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
    }

    @Test func windowsAlertsAndHostedContentInheritDarkAppearance() throws {
        let defaults = ScratchDefaults.make()
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        NSApplication.shared.appearance = nil
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        Appearance.apply(defaults: defaults)

        let host = NSHostingView(rootView: Text("AiTerm"))
        window.contentView = host
        let alert = NSAlert()
        alert.messageText = "Startup recovery"
        let alertWindow = alert.window
        let darkNames: [NSAppearance.Name] = [.darkAqua, .accessibilityHighContrastDarkAqua]
        for appearance in [window.effectiveAppearance, host.effectiveAppearance, alertWindow.effectiveAppearance] {
            #expect(darkNames.contains(appearance.name))
        }
    }
}
