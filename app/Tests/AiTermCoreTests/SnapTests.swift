import Testing
import Foundation
@testable import AiTermCore

@Suite struct SnapTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)   // visibleFrame: menu bar already excluded

    @Test func testTaskFrameFillsRightOfSidebar() {
        let sidebar = CGRect(x: 12, y: 0, width: 300, height: 875)
        #expect(Snap.taskFrame(sidebar: sidebar, screenVisible: screen) == CGRect(x: 324, y: 0, width: 1116, height: 875))
    }

    @Test func testSidebarOnOtherScreenOrTooWideFallsBackToFullScreen() {
        #expect(Snap.taskFrame(sidebar: CGRect(x: 2000, y: 0, width: 300, height: 875), screenVisible: screen) == screen)
        #expect(Snap.taskFrame(sidebar: CGRect(x: 0, y: 0, width: 1200, height: 875), screenVisible: screen) == screen)
    }

    @Test func testCoordinateConversion() {
        let r = CGRect(x: 324, y: 0, width: 1116, height: 875)
        #expect(Frame(r) == Frame(x: 324, y: 0, w: 1116, h: 875))
    }
}
