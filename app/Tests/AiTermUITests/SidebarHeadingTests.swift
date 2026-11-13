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

    /// The layered foundation's heading (13 Nov 2026): the section face, 11 semibold, in the third ink.
    @Test func itIsTheSectionFaceInTheThirdInk() {
        #expect(SidebarHeading.style == Typography.section)
        #expect(SidebarHeading.ink == Palette.tertiary)
    }

    /// Sentence case: the heading draws its words as given, untracked — as wide as the same words in the
    /// section face, and narrower than their capitals, which it used to draw.
    @Test func itDrawsItsWordsAsGiven() {
        func width(_ view: some View) -> CGFloat {
            let host = NSHostingView(rootView: view.fixedSize())
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let heading = width(SidebarHeading("In progress"))
        #expect(abs(heading - width(Text("In progress").font(Typography.section))) < 0.5)
        #expect(heading < width(Text("IN PROGRESS").font(Typography.section)))
    }
}
