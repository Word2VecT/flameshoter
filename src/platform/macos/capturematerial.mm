// SPDX-License-Identifier: GPL-3.0-or-later
#include "capturematerial.h"

#import <AppKit/AppKit.h>
#include <QWidget>

// Materials decorate Qt's capture canvas without consuming its input.
@interface FSCaptureGlass : NSGlassEffectView
@end
@implementation FSCaptureGlass
- (NSView*)hitTest:(NSPoint)point
{
    return nil;
}
@end

@interface FSCaptureFrost : NSVisualEffectView
@end
@implementation FSCaptureFrost
- (NSView*)hitTest:(NSPoint)point
{
    return nil;
}
@end

struct MacCaptureMaterial::Private
{
    __weak NSView* host;
    __strong FSCaptureFrost* frost;
    __strong FSCaptureGlass* glass;
    __strong NSTextField* dimensions;
    __strong FSCaptureGlass* warning;
    __strong NSTextField* warningText;
};

MacCaptureMaterial::MacCaptureMaterial(QWidget* host, int outsideOpacity)
  : d(std::make_unique<Private>())
{
    d->host = (__bridge NSView*)reinterpret_cast<void*>(host->winId());
    d->frost = [[FSCaptureFrost alloc] initWithFrame:d->host.bounds];
    d->frost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    d->frost.material = NSVisualEffectMaterialFullScreenUI;
    d->frost.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    d->frost.state = NSVisualEffectStateActive;
    d->frost.alphaValue =
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency
        ? 1.0
        : outsideOpacity / 255.0;
    [d->frost setAccessibilityElement:NO];
    [d->host addSubview:d->frost];
    d->glass = [FSCaptureGlass new];
    d->glass.style = NSGlassEffectViewStyleClear;
    d->glass.cornerRadius = 12;
    d->glass.contentView = [NSView new];
    d->dimensions = [NSTextField labelWithString:@""];
    d->dimensions.font =
      [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    d->dimensions.textColor = NSColor.labelColor;
    d->dimensions.hidden = YES;
    [d->glass.contentView addSubview:d->dimensions];
    d->glass.hidden = YES;
    [d->glass setAccessibilityElement:NO];
    [d->host addSubview:d->glass];
    d->warning = [FSCaptureGlass new];
    d->warning.style = NSGlassEffectViewStyleRegular;
    d->warning.cornerRadius = 12;
    d->warningText = [NSTextField wrappingLabelWithString:@""];
    d->warningText.textColor = NSColor.labelColor;
    d->warning.contentView = d->warningText;
    d->warning.hidden = YES;
    [d->host addSubview:d->warning];
}

MacCaptureMaterial::~MacCaptureMaterial()
{
    [d->glass removeFromSuperview];
    [d->frost removeFromSuperview];
    [d->warning removeFromSuperview];
}

void
MacCaptureMaterial::setSelection(const QRect& selection, bool visible)
{
    NSView* host = d->host;
    const BOOL selected = visible && !selection.isEmpty();
    const CGFloat y = host.isFlipped ? selection.y()
                                     : NSHeight(host.bounds) - selection.y() -
                                         selection.height();
    const NSRect aperture =
      NSMakeRect(selection.x(), y, selection.width(), selection.height());
    if (d->frost.maskImage &&
        NSEqualSizes(d->frost.maskImage.size, host.bounds.size) &&
        NSEqualRects(d->glass.frame, aperture) && d->glass.hidden == !selected)
        return;
    d->glass.hidden = !selected;
    d->glass.frame = aperture;
    const CGFloat radius = d->glass.cornerRadius;
    // Only geometry is drawn here; AppKit renders both materials.
    d->frost.maskImage =
      [NSImage imageWithSize:host.bounds.size
                     flipped:host.isFlipped
              drawingHandler:^BOOL(NSRect bounds) {
                NSBezierPath* mask = [NSBezierPath bezierPathWithRect:bounds];
                if (selected)
                    [mask appendBezierPathWithRoundedRect:aperture
                                                  xRadius:radius
                                                  yRadius:radius];
                mask.windingRule = NSWindingRuleEvenOdd;
                [NSColor.whiteColor setFill];
                [mask fill];
                return YES;
              }];
}

void
MacCaptureMaterial::setSelectionInfo(const QString& text, const QRect& bounds)
{
    NSView* host = d->host;
    d->dimensions.hidden = text.isEmpty();
    d->dimensions.stringValue = text.toNSString();
    const CGFloat y = host.isFlipped
                        ? bounds.y()
                        : NSHeight(host.bounds) - bounds.y() - bounds.height();
    NSRect frame = NSMakeRect(bounds.x(), y, bounds.width(), bounds.height());
    d->dimensions.frame = [host convertRect:frame toView:d->glass.contentView];
}

void
MacCaptureMaterial::setErrorMessage(const QString& text)
{
    NSView* host = d->host;
    d->warning.hidden = text.isEmpty();
    if (text.isEmpty())
        return;
    d->warningText.stringValue = text.toNSString();
    const CGFloat width = MIN(800, NSWidth(host.bounds) - 32);
    const CGFloat height =
      [d->warningText.cell
        cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)]
        .height +
      20;
    const CGFloat y = host.isFlipped ? NSHeight(host.bounds) - height - 16 : 16;
    d->warning.frame =
      NSMakeRect((NSWidth(host.bounds) - width) / 2, y, width, height);
}
