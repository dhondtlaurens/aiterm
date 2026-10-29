import AppKit
import SwiftUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite(.serialized) struct AppearanceTests {
    @Test func windowsAlertsAndHostedContentInheritDarkAppearance() throws {
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        NSApplication.shared.appearance = nil
        let window = testWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled])

        defer { window.close() }

        Appearance.apply()
        #expect(NSApplication.shared.appearance?.name == .darkAqua)

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
