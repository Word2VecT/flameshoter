// SPDX-License-Identifier: GPL-3.0-or-later
#include "platform/macos/dockicon.h"
#import <AppKit/AppKit.h>
#include <cstdio>
#include <cstdlib>

namespace {
void expect(bool ok, const char* message)
{
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}
void pump()
{
    auto until = [NSDate dateWithTimeIntervalSinceNow:0.04];
    while (NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                               untilDate:until
                                                  inMode:NSDefaultRunLoopMode
                                                 dequeue:YES])
        [NSApp sendEvent:event];
    [NSApp updateWindows];
}
void policy(NSApplicationActivationPolicy expected, const char* message)
{
    pump();
    expect(NSApp.activationPolicy == expected, message);
}
NSWindow* window(NSString* title)
{
    auto w = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(100, 100, 300, 160)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
    w.title = title;
    w.releasedWhenClosed = NO;
    return w;
}
void show(NSWindow* w)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [w makeKeyAndOrderFront:nil];
}
}

namespace {
void exerciseWindows()
{
#ifndef FLAMESHOTER_TEST_WITHOUT_DOCK_POLICY
    MacUI::installDockIconPolicy();
    MacUI::installDockIconPolicy();
#endif
    auto status = [NSStatusBar.systemStatusBar
      statusItemWithLength:NSVariableStatusItemLength];
    status.button.title = @"F";
    policy(NSApplicationActivationPolicyAccessory, "startup stays out of Dock");

    auto launcher = window(@"Flameshoter Dock Test — Launcher");
    auto settings = window(@"Flameshoter Dock Test — Settings");
    show(launcher);
    show(settings);
    policy(NSApplicationActivationPolicyRegular,
           "ordinary windows appear in Dock");
    [launcher close];
    policy(NSApplicationActivationPolicyRegular,
           "closing one of two windows keeps Dock");
    [settings close];
    policy(NSApplicationActivationPolicyAccessory,
           "closing the last window hides Dock");
    expect(status.visible && status.button != nil,
           "closing windows preserves menu bar item");

    for (int i = 0; i < 3; ++i) {
        show(settings);
        policy(NSApplicationActivationPolicyRegular,
               "a retained window can reopen");
        [settings orderOut:nil];
        policy(NSApplicationActivationPolicyAccessory,
               "orderOut hides the last window's Dock icon");
    }

    show(settings);
    [settings miniaturize:nil];
    for (int i = 0; i < 75 && !settings.miniaturized; ++i)
        pump();
    expect(settings.miniaturized, "window actually minimized");
    policy(NSApplicationActivationPolicyRegular, "minimized windows keep Dock");
    show(launcher);
    [launcher close];
    policy(NSApplicationActivationPolicyRegular,
           "another window closing preserves minimized window");
    [settings close];
    policy(NSApplicationActivationPolicyAccessory,
           "closing a minimized last window hides Dock");

    auto toolbar =
      [[NSPanel alloc] initWithContentRect:NSMakeRect(100, 100, 180, 40)
                                 styleMask:NSWindowStyleMaskBorderless |
                                           NSWindowStyleMaskNonactivatingPanel
                                   backing:NSBackingStoreBuffered
                                     defer:NO];
    toolbar.releasedWhenClosed = NO;
    [toolbar orderFront:nil];
    policy(NSApplicationActivationPolicyAccessory,
           "capture toolbar does not keep Dock alive");

    [NSApp orderFrontStandardAboutPanelWithOptions:@{}];
    policy(NSApplicationActivationPolicyRegular,
           "standard About panel appears in Dock");
    for (NSWindow* w in NSApp.windows)
        if (w != toolbar && w.visible)
            [w close];
    policy(NSApplicationActivationPolicyAccessory,
           "closing About hides Dock despite toolbar");
    [toolbar close];
    expect(status.visible, "menu bar remains after all windows close");
    [NSStatusBar.systemStatusBar removeStatusItem:status];
    std::puts("PASS: Dock lifecycle, multiple windows, reopening, minimizing, "
              "About and menu bar persistence");
}
}

int main()
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        dispatch_async(dispatch_get_main_queue(), ^{
          exerciseWindows();
          std::exit(0);
        });
        [NSApp run];
    }
}
