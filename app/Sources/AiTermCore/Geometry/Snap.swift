import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum Snap {
    public static func taskFrame(sidebar: CGRect, screenVisible: CGRect, gap: CGFloat = 12) -> CGRect {
        guard screenVisible.intersects(sidebar) else { return screenVisible }
        let x = sidebar.maxX + gap
        let w = screenVisible.maxX - x
        guard w >= 400 else { return screenVisible }
        return CGRect(x: x, y: screenVisible.minY, width: w, height: screenVisible.height)
    }
}

public extension Frame {
    /// iTerm2 frames are in Cocoa coordinates — "0,0 is the bottom left coordinate" (iTerm2 Python
    /// API docs, `iterm2.util.Frame`, checked live 2026-09-17) — so an AppKit rect passes through
    /// unflipped, on every screen.
    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), w: Double(rect.width), h: Double(rect.height))
    }
}
