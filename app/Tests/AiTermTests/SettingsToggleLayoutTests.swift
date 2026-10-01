import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermCore
@testable import AiTerm

@MainActor
struct SettingsToggleLayoutTests {
    private func settings(_ preferences: InterfacePreferences, setMatchItermBackground: @escaping (Bool) -> Void = { _ in },
                          setInterfaceSize: @escaping (InterfaceSize) -> Void = { _ in }) -> SettingsView {
        SettingsView(jiraConfig: nil, gitLabConfig: nil,
                     harnessModel: HarnessSettingsModel.preview(),
                     itermConnection: { .connected(version: "3.7.2") },
                     checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                     preferences: preferences, setMatchItermBackground: setMatchItermBackground,
                     setInterfaceSize: setInterfaceSize, initialTab: .interface)
    }

    /// Settings opens on the switches as last saved, and Save hands the sidebar what they now say.
    @Test func badgeSwitchesOpenAsSavedAndSaveAppliesThem() {
        let preferences = InterfacePreferences.scratch()
        let trimmed = BadgeDetails(jiraProject: true, jiraTicket: false, mergeRequest: true, diff: false)
        preferences.badgeDetails = trimmed
        let settings = settings(preferences)
        #expect(settings._badgeDetails.wrappedValue == trimmed)
        preferences.badgeDetails = BadgeDetails()
        settings.saveInterface()
        #expect(preferences.badgeDetails == trimmed)
    }

    /// Settings opens on the size and the background switch as last saved, and Save hands both on
    /// to be stored and applied.
    @Test func sizeAndBackgroundOpenAsSavedAndSaveAppliesThem() {
        let preferences = InterfacePreferences.scratch()
        preferences.interfaceSize = .large
        preferences.matchItermBackground = true
        var size: InterfaceSize?, background: Bool?
        let settings = settings(preferences, setMatchItermBackground: { background = $0 }, setInterfaceSize: { size = $0 })
        #expect(settings._interfaceSize.wrappedValue == .large)
        #expect(settings._matchItermBackground.wrappedValue)
        settings.saveInterface()
        #expect(size == .large)
        #expect(background == true)
    }

    /// A picked size reaches the sidebar at once, before Save, and Cancel puts back the size the
    /// sheet opened on.
    @Test func aPickedSizeAppliesAtOnceAndCancelPutsTheOpeningOneBack() {
        let preferences = InterfacePreferences.scratch()
        preferences.interfaceSize = .standard
        var sizes: [InterfaceSize] = []
        let settings = settings(preferences, setInterfaceSize: { sizes.append($0) })
        settings.pickInterfaceSize(.large)
        #expect(sizes == [.large])
        settings.pickInterfaceSize(.extraLarge)
        #expect(sizes == [.large, .extraLarge])
        settings.cancel()
        #expect(sizes == [.large, .extraLarge, .standard])
    }

    /// The Interface tab's preference follows the native System Settings row: its switch stays compact
    /// and pinned to the card's trailing inset instead of sitting directly after the title.
    @Test func interfaceSwitchIsCompactAndTrailingAligned() throws {
        let preferences = InterfacePreferences.scratch()
        preferences.matchItermBackground = true
        let settings = settings(preferences)
        #expect(settings._matchItermBackground.wrappedValue)
        let host = NSHostingView(rootView: settings)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.settingsHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let components = components(from: lightRuns(in: bitmap, scale: scale))
        let switchThumb = try #require(components
            .filter { 14...40 ~= $0.width && 14...30 ~= $0.height }
            .max { $0.width * $0.height < $1.width * $1.height }, "light components: \(components)")

        #expect(switchThumb.width <= 17,
                "switch thumb width \(switchThumb.width) should use the compact native size")
        // The tab is taller than the sheet, so it scrolls; a legacy scroller (a mouse attached, or
        // "Show scroll bars: Always") takes its width from the cards, an overlay one takes none.
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        #expect(switchThumb.maxX >= 515 - scroller,
                "switch trailing edge \(switchThumb.maxX) with \(switchThumb.width) pt thumb should reach the card's 16 pt inset")
    }

    /// Finds continuous light bands. The switch thumb is the only solid light component in the
    /// target size range; text is split into individual glyphs and buttons use a dark fill.
    /// Returning point-space rectangles keeps the assertions stable at either Retina scale.
    private func lightRuns(in bitmap: NSBitmapImageRep, scale: CGFloat) -> [CGRect] {
        var runs: [CGRect] = []
        for y in 0..<bitmap.pixelsHigh {
            var start: Int?
            for x in 0...bitmap.pixelsWide {
                let light = x < bitmap.pixelsWide && bitmap.colorAt(x: x, y: y).map {
                    $0.redComponent > 0.65 && $0.greenComponent > 0.65 && $0.blueComponent > 0.65
                } == true
                if light, start == nil { start = x }
                if !light, let lower = start {
                    let width = x - lower
                    if CGFloat(width) / scale >= 4 {
                        runs.append(CGRect(x: CGFloat(lower) / scale, y: CGFloat(y) / scale,
                                           width: CGFloat(width) / scale, height: 1 / scale))
                    }
                    start = nil
                }
            }
        }
        return runs
    }

    private func components(from runs: [CGRect]) -> [CGRect] {
        var components: [CGRect] = []
        for run in runs {
            if let index = components.indices.last(where: { component in
                components[component].maxY >= run.minY - 1
                    && components[component].minX <= run.maxX
                    && components[component].maxX >= run.minX
            }) {
                components[index] = components[index].union(run)
            } else {
                components.append(run)
            }
        }
        return components
    }
}
