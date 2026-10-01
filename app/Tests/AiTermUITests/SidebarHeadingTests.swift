import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
struct SidebarHeadingTests {
    /// A sidebar heading grows with the sidebar, like every row it heads.
    @Test func itGrowsWithTheSidebar() {
        func size(_ scale: InterfaceScale) -> CGSize {
            let host = NSHostingView(rootView: SidebarHeading("Projects").fixedSize().interfaceScale(scale))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let standard = size(.standard), extraLarge = size(.extraLarge)
        #expect(extraLarge.height > standard.height)
        #expect(extraLarge.width > standard.width)
    }
}
