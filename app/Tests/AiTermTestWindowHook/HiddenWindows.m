#import "AiTermTestWindowHook.h"
#import <objc/runtime.h>

// Hides every window the test process orders in: transparent and click-through. Test windows are
// real windows, so a run drew them over AiTerm, iTerm2 and whatever else the person was working in,
// and took the clicks meant for those. Moving them off screen does not work — AppKit constrains a
// titled window back onto the screen, to (0, 0) — and nothing they test needs to be seen: a test
// types and clicks by `sendEvent`, and reads pixels by `cacheDisplay`, neither of which asks the
// window server what is showing. A window at alpha 0 is still ordered in and laid out, and can be
// key.
//
// Every way of ordering a window in — `makeKeyAndOrderFront:`, `orderFront:`, a popover's window, a
// sheet, a child window — goes through `orderWindow:relativeTo:`, except `orderFrontRegardless`,
// which is exchanged too. The window is hidden before the original runs, so it is never drawn
// visible for a frame, and a popover's open animation does not bring the alpha back.
//
// This target is linked only into the tests (AiTermTestSupport depends on it), never into the app.
// `+load` runs when the test bundle loads, before any test makes a window; the object file is kept
// in the link because `keepVisible` calls `AiTermTestKeepWindowVisible` from it.

static char keptVisibleKey;

void AiTermTestKeepWindowVisible(NSWindow *window) {
    objc_setAssociatedObject(window, &keptVisibleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void hide(NSWindow *window) {
    if (objc_getAssociatedObject(window, &keptVisibleKey) != nil) return;
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
}

static void exchange(SEL original, SEL replacement) {
    method_exchangeImplementations(class_getInstanceMethod([NSWindow class], original),
                                   class_getInstanceMethod([NSWindow class], replacement));
}

@implementation NSWindow (AiTermTestHiddenWindows)

+ (void)load {
    exchange(@selector(orderWindow:relativeTo:), @selector(aiTermTest_orderWindow:relativeTo:));
    exchange(@selector(orderFrontRegardless), @selector(aiTermTest_orderFrontRegardless));
}

// After the exchange these names call AppKit's originals.
- (void)aiTermTest_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWindowNumber {
    if (place != NSWindowOut) hide(self);
    [self aiTermTest_orderWindow:place relativeTo:otherWindowNumber];
}

- (void)aiTermTest_orderFrontRegardless {
    hide(self);
    [self aiTermTest_orderFrontRegardless];
}

@end
