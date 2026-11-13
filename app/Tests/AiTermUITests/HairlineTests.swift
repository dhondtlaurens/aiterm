import AppKit
import SwiftUI
import Testing
@testable import AiTermTestSupport
@testable import AiTermUI

@MainActor
struct HairlineTests {
    /// Beside a label in an `HStack` — `DividerRow`'s rule either side of its name — the hairline
    /// stays a horizontal 1 pt rule, which SwiftUI's `Divider` does not, and a stroke does not grow
    /// with the sidebar's scale.
    @Test func itIsAHorizontalPointAtEveryScale() {
        for scale in InterfaceScale.all {
            let box = Box()
            let host = NSHostingView(rootView: HStack {
                Hairline().background(GeometryReader { proxy in Color.clear.onAppear { box.size = proxy.size } })
                Text("Work")
                Hairline()
            }
            .frame(width: 200)
            .interfaceScale(scale))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            AiTermTestSupport.settle(host) { box.size != .zero }
            #expect(box.size.height == 1, "at ×\(scale.factor)")
            #expect(box.size.width > 50, "at ×\(scale.factor)")
        }
    }

    private final class Box { var size = CGSize.zero }

    /// A sheet's section break and the sidebar's rule are one weight: the hairline draws exactly
    /// the soft `border` a card is edged in, not a brighter `Divider` under it, and not the firm
    /// `borderStrong` a field is outlined in.
    @Test func itDrawsTheBorder() throws {
        let hairline = try #require(brightestPixel(of: VStack { Hairline() }.frame(width: 20)))
        let border = try #require(brightestPixel(of: Rectangle().fill(Palette.border).frame(width: 20, height: 1)))
        let strong = try #require(brightestPixel(of: Rectangle().fill(Palette.borderStrong).frame(width: 20, height: 1)))
        #expect(abs(hairline.redComponent - border.redComponent) < 0.005,
                "hairline \(hairline.redComponent), border \(border.redComponent)")
        #expect(strong.redComponent - hairline.redComponent > 0.01,
                "hairline \(hairline.redComponent) is as firm as a field's edge \(strong.redComponent)")
    }
}
