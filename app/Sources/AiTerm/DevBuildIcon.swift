import AppKit
import AiTermCore
import AiTermUI

/// A dev build's Dock icon: the app icon with a DEV pill across its bottom edge, so a local build
/// never passes for the release in Applications. It replaces only the running app's image — Finder
/// and a Dock that is not running AiTerm still show the bundle's own icon — and it leaves the top
/// right corner to `dockTile.badgeLabel`, which counts the rows Focus View steps through.
@MainActor
enum DevBuildIcon {
    static func apply(channel: BuildChannel = BuildChannel(infoDictionary: Bundle.main.infoDictionary)) {
        guard channel == .dev, let icon = NSApp.applicationIconImage else { return }
        NSApp.applicationIconImage = badged(icon)
    }

    /// Fractions of the icon's side, not `Metrics` points: the Dock scales the icon anywhere from
    /// 16 to 512 points and the pill has to scale with it. The app icon is drawn on Apple's grid —
    /// a 1024 canvas whose rounded square stops about 0.1 short of each edge — so a pill from 0.04 to
    /// 0.24 straddles the square's bottom edge.
    private static let pillWidth = 0.56, pillHeight = 0.2, pillBottom = 0.04, letterSize = 0.13

    static func badged(_ icon: NSImage) -> NSImage {
        let fill = NSColor(Palette.devBuild), ink = NSColor(Palette.devBuildInk)
        // A drawing handler, not a bitmap: AppKit redraws it at whatever size and scale the Dock
        // asks for, so the lettering stays sharp at every magnification.
        return NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            let side = min(rect.width, rect.height)
            let pill = NSRect(x: rect.midX - side * pillWidth / 2, y: rect.minY + side * pillBottom,
                              width: side * pillWidth, height: side * pillHeight)
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            let text = NSAttributedString(string: "DEV", attributes: [
                .font: NSFont.systemFont(ofSize: side * letterSize, weight: .heavy),
                .foregroundColor: ink,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
            return true
        }
    }
}
