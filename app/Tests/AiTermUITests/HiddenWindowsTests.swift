import AppKit
import Testing
import AiTermTestSupport

// The test process hides every window it orders in (AiTermTestWindowHook): transparent and
// click-through, so a run no longer draws over the person's apps. These make their windows the way
// a test outside the helpers would — no `testWindow`, no `testPanel` — so they show the hook needs
// no call to apply.
@MainActor @Suite(.serialized)
struct HiddenWindowsTests {
    /// A window made in code, kept alive when closed (ARC owns it), with no open or close animation.
    private func plainWindow<W: NSWindow>(_ type: W.Type = NSWindow.self, styleMask: NSWindow.StyleMask = [.titled],
                                          size: NSSize = NSSize(width: 240, height: 160)) -> W {
        let window = W(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size), styleMask: styleMask,
                       backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    /// The window server's alpha for `window` once it lists the window on screen, which it does a
    /// run-loop turn or so after the window is ordered in; nil if it never does.
    private func windowServerAlpha(of window: NSWindow) -> Double? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }) {
                return entry[kCGWindowAlpha as String] as? Double
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return nil
    }

    @Test func aWindowOrderedFrontIsTransparentAndClickThrough() {
        let window = plainWindow()
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)

        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(windowServerAlpha(of: window) == 0, "ordered in, and drawn by the window server at alpha 0")
    }

    @Test func aPanelOrderedFrontRegardlessIsHidden() {
        let panel = plainWindow(NSPanel.self)
        defer { panel.close() }
        panel.orderFrontRegardless()

        #expect(panel.isVisible)
        #expect(panel.alphaValue == 0)
        #expect(panel.ignoresMouseEvents)
    }

    /// AppKit orders these in itself, each in a window of its own: a popover's private window, a
    /// sheet, a child window.
    @Test func popoversSheetsAndChildWindowsAreHidden() {
        // Only the windows this test opens are read: another test's may be open, and kept visible.
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let parent = plainWindow()
        parent.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        parent.makeKeyAndOrderFront(nil)

        let popover = NSPopover()
        popover.animates = false
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        popover.contentViewController = content
        popover.show(relativeTo: NSRect(x: 10, y: 10, width: 10, height: 10), of: parent.contentView!, preferredEdge: .maxY)

        let sheet = plainWindow(size: NSSize(width: 120, height: 80))
        parent.beginSheet(sheet)
        let child = plainWindow(styleMask: [.borderless], size: NSSize(width: 50, height: 50))
        parent.addChildWindow(child, ordered: .above)
        settle(parent.contentView!)
        defer {
            popover.close()
            parent.removeChildWindow(child)
            child.close()
            parent.endSheet(sheet)
            sheet.close()
            parent.close()
        }

        let opened = NSApp.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
        #expect(opened.count >= 4, "the parent, the popover's window, the sheet and the child: \(opened)")
        #expect(opened.contains { $0 === content.view.window }, "the popover's window is ordered in")
        for window in opened {
            #expect(window.alphaValue == 0, "\(type(of: window)) is drawn")
            #expect(window.ignoresMouseEvents, "\(type(of: window)) takes clicks")
        }
    }

    /// Tests type into hidden windows by sending them events, which needs no window anyone can see.
    @Test func aHiddenWindowStillTakesSentEvents() throws {
        let window = plainWindow()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 200, height: 24))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        window.contentView!.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        #expect(window.alphaValue == 0)
        window.makeFirstResponder(field)

        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "a",
                                                       charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)))
        #expect(field.stringValue == "a")
    }

    @Test func aKeptWindowStaysVisible() {
        let window = plainWindow()
        defer { window.close() }
        keepVisible(window)
        window.orderFront(nil)

        #expect(window.alphaValue == 1)
        #expect(!window.ignoresMouseEvents)
        #expect(windowServerAlpha(of: window) == 1, "the control: the window server's alpha tells a hidden window apart")
    }
}
