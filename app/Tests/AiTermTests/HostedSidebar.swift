import AppKit
import SwiftUI
import AiTermTestSupport
@testable import AiTerm

@MainActor enum HostedSidebar {
    static func make(_ controller: AppController, size: CGSize = CGSize(width: 340, height: 500),
                     key: Bool = false) -> (NSHostingView<SidebarView>, NSWindow) {
        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(origin: .zero, size: size)
        let window = testWindow(hosting: host, orderFront: key)
        if !key { window.orderFront(nil) }
        return (host, window)
    }
}
