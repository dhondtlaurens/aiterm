import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
struct FrontToBackStackTests {
    /// What shows at the middle of the second child, which a panel hanging out of the first covers.
    private static func colour(under stack: some View) throws -> NSColor {
        let host = NSHostingView(rootView: stack.frame(width: 20, height: 40).background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 40)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        // The middle of the second child, which the first one's panel covers.
        return try #require(bitmap.colorAt(x: Int(10 * scale), y: Int(30 * scale))?.usingColorSpace(.sRGB))
    }

    @Test func anEarlierChildsOverhangDrawsOverTheLaterOnes() throws {
        let stack = FrontToBackStack(spacing: 0) {
            Color.red.frame(width: 20, height: 20)
                .overlay(alignment: .top) { Color.blue.frame(width: 20, height: 20).offset(y: 20) }
            Color.green.frame(width: 20, height: 20)
        }
        let inked = try Self.colour(under: stack)
        #expect(inked.blueComponent > inked.greenComponent + 0.3, "the green child covers the blue panel: \(inked)")

        let plain = VStack(alignment: .leading, spacing: 0) {
            Color.red.frame(width: 20, height: 20)
                .overlay(alignment: .top) { Color.blue.frame(width: 20, height: 20).offset(y: 20) }
            Color.green.frame(width: 20, height: 20)
        }
        let covered = try Self.colour(under: plain)
        #expect(covered.greenComponent > covered.blueComponent + 0.3, "the control: a VStack does draw the later child over it")
    }

    @Test func itLaysOutLikeAVStack() throws {
        func size(of view: some View) -> CGSize {
            NSHostingView(rootView: view.fixedSize()).fittingSize
        }
        let children = {
            Group {
                Text("Label"); Text("Control")
                if true { Text("Help") }
            }
        }
        let stacked = size(of: FrontToBackStack(alignment: .leading, spacing: 6) { children() })
        let plain = size(of: VStack(alignment: .leading, spacing: 6) { children() })
        #expect(stacked == plain)
    }
}
