// SPDX-License-Identifier: GPL-3.0-or-later
#include "dockicon.h"
#import <AppKit/AppKit.h>

namespace {
void updateDockIcon()
{
    bool hasWindow = false;
    for (NSWindow* window in NSApp.windows) {
        const auto style = window.styleMask;
        if ((window.visible || window.miniaturized) &&
            (style & NSWindowStyleMaskTitled) &&
            !(style & NSWindowStyleMaskUtilityWindow) &&
            !(style & NSWindowStyleMaskNonactivatingPanel)) {
            hasWindow = true;
            break;
        }
    }
    const auto policy = hasWindow ? NSApplicationActivationPolicyRegular
                                  : NSApplicationActivationPolicyAccessory;
    if (NSApp.activationPolicy != policy)
        [NSApp setActivationPolicy:policy];
}
}

void MacUI::installDockIconPolicy()
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      // Recompute after AppKit finishes updating window visibility, including
      // close/orderOut. Both native windows and Qt's NSWindows participate.
      [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidUpdateNotification
                    object:NSApp
                     queue:nil
                usingBlock:^(NSNotification*) {
                  updateDockIcon();
                }];
    });
}
