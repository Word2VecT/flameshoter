// SPDX-License-Identifier: GPL-3.0-or-later
#include "platform/macos/capturematerial.h"

#import <AppKit/AppKit.h>
#include <QApplication>
#include <QWidget>
#include <cstdio>
#include <cstdlib>

static void
require(bool condition, const char* message)
{
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

int
main(int argc, char** argv)
{
    QApplication application(argc, argv);
    QWidget canvas;
    canvas.resize(640, 480);
    NSView* host = (__bridge NSView*)reinterpret_cast<void*>(canvas.winId());
    for (NSAppearanceName appearance :
         @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        host.appearance = [NSAppearance appearanceNamed:appearance];
        const NSUInteger originalSubviews = host.subviews.count;
        {
            MacCaptureMaterial material(&canvas, 190);
            NSVisualEffectView* frost = nil;
            NSGlassEffectView* glass = nil;
            for (NSView* view in host.subviews) {
                if ([view isKindOfClass:NSVisualEffectView.class])
                    frost = (NSVisualEffectView*)view;
                if ([view isKindOfClass:NSGlassEffectView.class] &&
                    ((NSGlassEffectView*)view).style ==
                      NSGlassEffectViewStyleClear)
                    glass = (NSGlassEffectView*)view;
            }
            require(frost.material == NSVisualEffectMaterialFullScreenUI,
                    "system fullscreen material");
            require(frost.blendingMode ==
                      NSVisualEffectBlendingModeWithinWindow,
                    "sample frozen capture canvas");
            require(glass != nil, "system clear Liquid Glass selection");
            require(glass.hidden, "no selection initially");
            material.setSelection(QRect(160, 120, 320, 240), true);
            require(!glass.hidden, "show selected glass");
            require(NSEqualSizes(glass.frame.size, NSMakeSize(320, 240)),
                    "selection geometry stays exact");
            require([glass hitTest:NSMakePoint(20, 20)] == nil,
                    "glass leaves drawing input to canvas");
            require([frost hitTest:NSMakePoint(20, 20)] == nil,
                    "frost leaves selection input to canvas");
            CGImageRef mask = [frost.maskImage CGImageForProposedRect:nullptr
                                                              context:nil
                                                                hints:nil];
            NSBitmapImageRep* pixels =
              [[NSBitmapImageRep alloc] initWithCGImage:mask];
            require([pixels colorAtX:pixels.pixelsWide / 2
                                   y:pixels.pixelsHigh / 2]
                        .alphaComponent < 0.01,
                    "selected pixels are excluded from frost");
            require([pixels colorAtX:0 y:0].alphaComponent > 0.99,
                    "outside pixels receive system frost");
            material.setSelectionInfo(QStringLiteral("640 × 480"),
                                      QRect(170, 130, 110, 24));
            require([glass.contentView.subviews.firstObject
                      isKindOfClass:NSTextField.class],
                    "native dimension label above glass");
            material.setSelection(QRect(40, 40, 80, 60), true);
            require(NSEqualSizes(glass.frame.size, NSMakeSize(80, 60)),
                    "moving and resizing the selection");
            material.setSelection({}, false);
            require(glass.hidden, "clearing selection hides glass");
            mask = [frost.maskImage CGImageForProposedRect:nullptr
                                                   context:nil
                                                     hints:nil];
            pixels = [[NSBitmapImageRep alloc] initWithCGImage:mask];
            require([pixels colorAtX:pixels.pixelsWide / 2
                                   y:pixels.pixelsHigh / 2]
                        .alphaComponent > 0.99,
                    "clearing selection restores fullscreen frost");
        }
        require(host.subviews.count == originalSubviews,
                "native material lifecycle cleanup");
    }
    std::puts("PASS: native capture materials, aperture, input passthrough, "
              "geometry, light/dark and cleanup");
}
