import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// Renders the sidebar, every sheet and every Settings tab to PNGs, offscreen, so the
/// implementation can be checked against the design without a screen recorder.
/// Only runs when `AITERM_SNAPSHOT_DIR` is set; `scripts/snapshots.sh` is the front door, and it
/// runs the debug build, so a release build carries none of this.
///
/// Each image is a `Snapshot`: a file name and a view built from a fixture of its own, so no image
/// depends on another having been drawn first. The README's picture is drawn last and apart
/// (`ReadmeDesktop`): it is artwork, not one of the views being checked.
@MainActor
enum Snapshots {
    /// The one instant every image is drawn at, and the calendar it is read in. Fixture times and
    /// the footer's "now" come from here, never the wall clock, so two runs — an hour or a month
    /// apart, on any machine — draw the same labels. Midday UTC on a Wednesday: a reset two hours
    /// on shares the day, one three days on is a Saturday.
    static let clock: FooterClock = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return FooterClock(now: Date(timeIntervalSince1970: 1_773_230_400), calendar: calendar)  // 2026-03-11 12:00 UTC
    }()

    /// Whether the images are drawn by a real window (`AITERM_SNAPSHOT_HOSTED=1`) rather than
    /// `ImageRenderer`, which cannot draw AppKit-backed controls or a `List`.
    static let hosted = ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_HOSTED"] == "1"

    /// The regression set, in the order it is drawn — the order it has always been drawn in: no
    /// image reads another's fixture, but `ImageRenderer`'s antialiasing of one has been seen to
    /// move by a level with what was drawn before it, so an added image is checked against the
    /// images drawn after it.
    static var regressionSet: [Snapshot] {
        SidebarSnapshots.rows + SheetSnapshots.all + SettingsSnapshots.all + [SidebarSnapshots.marks]
            + SidebarSnapshots.states
    }

    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_DIR"] else { return false }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for snapshot in regressionSet + [ReadmeDesktop.snapshot] where hosted || !snapshot.hostedOnly {
            write(snapshot.view(), to: out.appendingPathComponent(snapshot.file))
        }

        print("snapshots written to \(out.path)")
        return true
    }

    private static func write(_ view: some View, to url: URL) {
        if hosted {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.footerClock, clock))
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_NATIVE_CAPTURE"] == "1" {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
                try? capture.run()
                capture.waitUntilExit()
                if capture.terminationStatus == 0 { window.orderOut(nil); return }
                print("WindowServer capture unavailable for \(url.lastPathComponent); using view capture")
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
            }
            window.orderOut(nil)
            return
        }
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.snapshotRendering, true)
            .environment(\.footerClock, clock))
        renderer.scale = 2
        // `colorScheme` reaches SwiftUI; an AppKit colour resolves against the drawing appearance,
        // which is the app's only while `Appearance.apply` has run. Pinned here, the images are
        // dark whatever the process or the system is set to.
        var png: Data?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return }
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { print("could not render \(url.lastPathComponent)"); return }
        try? png.write(to: url)
    }
}

/// One image: the file it is written to and the view it draws, built when it is drawn and from
/// nothing another image touched.
struct Snapshot {
    let file: String
    /// Drawn only by the hosted renderer: `ImageRenderer` never materialises a `List`.
    let hostedOnly: Bool
    let view: @MainActor () -> AnyView

    init<Content: View>(_ file: String, hostedOnly: Bool = false, view: @escaping @MainActor () -> Content) {
        self.file = file
        self.hostedOnly = hostedOnly
        self.view = { AnyView(view()) }
    }
}

/// Set while `ImageRenderer` draws, which cannot materialise a `ScrollView`'s contents:
/// `SheetLayout` then lays its content out flat and clipped instead.
private struct SnapshotRenderingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}
#endif
