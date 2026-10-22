#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Leaves `window` drawn and clickable: the test process otherwise hides every window it orders in
/// (HiddenWindows.m). For the rare test that needs the window server to show or hit-test a window.
void AiTermTestKeepWindowVisible(NSWindow *window);

NS_ASSUME_NONNULL_END
