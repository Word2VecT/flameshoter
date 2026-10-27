// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Flameshoter contributors
#include "nativeui.h"
#include "core/flameshot.h"
#include "utils/confighandler.h"
#include "widgets/capture/capturetoolbutton.h"

#include <QApplication>
#include <QLocale>
#include <QPointer>
#include <QProcess>
#include <QTimer>
#include <QWidget>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

namespace {
NSString* ns(const QString& s) { return s.toNSString(); }
QString qs(NSString* s) { return QString::fromNSString(s ?: @""); }
bool chinese()
{
    const auto language = ConfigHandler().uiLanguage();
    return language.startsWith("zh") ||
           (language == "auto" && QLocale::system().language() == QLocale::Chinese);
}
NSString* L(NSString* english, NSString* zh) { return chinese() ? zh : english; }
NSColor* nativeColor(const QColor& c)
{
    return [NSColor colorWithSRGBRed:c.redF() green:c.greenF()
                              blue:c.blueF() alpha:c.alphaF()];
}
QColor qtColor(NSColor* c)
{
    c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return QColor::fromRgbF(c.redComponent, c.greenComponent, c.blueComponent,
                           c.alphaComponent);
}
}

@interface FSAction : NSObject
@property(copy) void (^block)(id);
- (void)perform:(id)sender;
@end
@implementation FSAction
- (void)perform:(id)sender { if (_block) _block(sender); }
@end

@interface FSGlassContainer : NSGlassEffectContainerView
@property(copy) void (^hover)(BOOL);
@property(strong) NSTrackingArea* tracking;
@end
@implementation FSGlassContainer
- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent*)event { if (_hover) _hover(YES); }
- (void)mouseExited:(NSEvent*)event { if (_hover) _hover(NO); }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.arrowCursor]; }
@end

namespace {
void action(NSControl* control, void (^block)(id))
{
    auto target = [FSAction new];
    target.block = block;
    control.target = target;
    control.action = @selector(perform:);
    objc_setAssociatedObject(control, @selector(perform:), target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
NSStackView* stack(NSArray<NSView*>* views, NSUserInterfaceLayoutOrientation axis,
                   CGFloat spacing = 12)
{
    auto s = [NSStackView stackViewWithViews:views];
    s.orientation = axis;
    s.spacing = spacing;
    s.alignment = axis == NSUserInterfaceLayoutOrientationVertical
                    ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}
NSTextField* label(NSString* text, CGFloat size = 13, BOOL secondary = NO)
{
    auto l = [NSTextField wrappingLabelWithString:text];
    l.font = [NSFont systemFontOfSize:size];
    l.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}
NSView* padded(NSView* content, CGFloat padding)
{
    auto view = [NSView new];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:content];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:padding],
        [content.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-padding],
        [content.topAnchor constraintEqualToAnchor:view.topAnchor constant:padding],
        [content.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-padding]]];
    return view;
}
NSButton* button(NSString* title, NSString* symbol, void (^block)(id))
{
    auto b = [NSButton buttonWithTitle:title target:nil action:nil];
    b.bezelStyle = NSBezelStyleRounded;
    if (symbol) {
        b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
        b.imagePosition = title.length ? NSImageLeading : NSImageOnly;
    }
    action(b, block);
    return b;
}
NSButton* iconButton(NSString* title, NSString* symbol, void (^block)(id))
{
    auto b = button(@"", symbol, block);
    b.toolTip = title;
    [b setAccessibilityLabel:title];
    b.bezelStyle = NSBezelStyleAccessoryBarAction;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:34].active = YES;
    [b.heightAnchor constraintEqualToConstant:34].active = YES;
    return b;
}
NSGlassEffectView* glass(NSView* content)
{
    auto g = [NSGlassEffectView new];
    g.style = NSGlassEffectViewStyleRegular;
    g.cornerRadius = 25;
    g.contentView = padded(content, 8);
    g.translatesAutoresizingMaskIntoConstraints = NO;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
    if (@available(macOS 27.0, *)) g.effectIsInteractive = YES;
#endif
    return g;
}
NSString* symbol(int type)
{
    switch (type) {
    case CaptureTool::TYPE_PENCIL: return @"pencil.tip";
    case CaptureTool::TYPE_DRAWER: return @"line.diagonal";
    case CaptureTool::TYPE_ARROW: return @"arrow.up.right";
    case CaptureTool::TYPE_SELECTION: return @"cursorarrow";
    case CaptureTool::TYPE_RECTANGLE: return @"rectangle";
    case CaptureTool::TYPE_CIRCLE: return @"circle";
    case CaptureTool::TYPE_MARKER: return @"highlighter";
    case CaptureTool::TYPE_MOVESELECTION: return @"arrow.up.and.down.and.arrow.left.and.right";
    case CaptureTool::TYPE_UNDO: return @"arrow.uturn.backward";
    case CaptureTool::TYPE_COPY: return @"document.on.document";
    case CaptureTool::TYPE_SAVE: return @"square.and.arrow.down";
    case CaptureTool::TYPE_EXIT: return @"xmark";
    case CaptureTool::TYPE_OPEN_APP: return @"square.and.arrow.up";
    case CaptureTool::TYPE_PIXELATE: return @"square.dashed.inset.filled";
    case CaptureTool::TYPE_REDO: return @"arrow.uturn.forward";
    case CaptureTool::TYPE_PIN: return @"pin";
    case CaptureTool::TYPE_TEXT: return @"textformat";
    case CaptureTool::TYPE_CIRCLECOUNT: return @"number.circle";
    case CaptureTool::TYPE_SIZEINCREASE: return @"plus";
    case CaptureTool::TYPE_SIZEDECREASE: return @"minus";
    case CaptureTool::TYPE_INVERT: return @"circle.lefthalf.filled";
    case CaptureTool::TYPE_ACCEPT: return @"checkmark";
    case CaptureTool::TYPE_CANCEL: return @"escape";
    default: return @"ellipsis";
    }
}
NSString* toolName(CaptureToolButton* b)
{
    // These explicit labels also cover a missing or outdated upstream catalog.
    switch (b->tool()->type()) {
    case CaptureTool::TYPE_PENCIL: return L(@"Pencil", @"画笔");
    case CaptureTool::TYPE_DRAWER: return L(@"Line", @"直线");
    case CaptureTool::TYPE_ARROW: return L(@"Arrow", @"箭头");
    case CaptureTool::TYPE_SELECTION: return L(@"Select annotation", @"选择标注");
    case CaptureTool::TYPE_RECTANGLE: return L(@"Rectangle", @"矩形");
    case CaptureTool::TYPE_CIRCLE: return L(@"Ellipse", @"椭圆");
    case CaptureTool::TYPE_MARKER: return L(@"Highlighter", @"荧光笔");
    case CaptureTool::TYPE_MOVESELECTION: return L(@"Move capture region", @"移动截图区域");
    case CaptureTool::TYPE_UNDO: return L(@"Undo", @"撤销");
    case CaptureTool::TYPE_REDO: return L(@"Redo", @"重做");
    case CaptureTool::TYPE_COPY: return L(@"Copy", @"复制");
    case CaptureTool::TYPE_SAVE: return L(@"Save", @"保存");
    case CaptureTool::TYPE_EXIT: return L(@"Cancel capture", @"取消截图");
    case CaptureTool::TYPE_OPEN_APP: return L(@"Open in app", @"在其他应用中打开");
    case CaptureTool::TYPE_PIXELATE: return L(@"Pixelate", @"马赛克");
    case CaptureTool::TYPE_PIN: return L(@"Pin", @"置顶截图");
    case CaptureTool::TYPE_TEXT: return L(@"Text", @"文字");
    case CaptureTool::TYPE_CIRCLECOUNT: return L(@"Number", @"序号");
    case CaptureTool::TYPE_SIZEINCREASE: return L(@"Increase size", @"增大尺寸");
    case CaptureTool::TYPE_SIZEDECREASE: return L(@"Decrease size", @"减小尺寸");
    case CaptureTool::TYPE_INVERT: return L(@"Invert colors", @"反转颜色");
    case CaptureTool::TYPE_ACCEPT: return L(@"Done", @"完成");
    case CaptureTool::TYPE_CANCEL: return L(@"Clear selection", @"清除选区");
    default: return ns(b->tool()->name());
    }
}
void activate(NSWindow* window)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
}

struct MacCaptureBar::Private {
    QPointer<QWidget> widget;
    __strong FSGlassContainer* root;
    __strong NSGlassEffectView* hint;
    __strong NSPanel* panel;
    __weak NSView* host;
    QRect barRect;
    __strong NSPopover* inspector;
    __strong NSColorWell* color;
    __strong NSSlider* thickness;
    __strong NSTextField* sizeLabel;
    __strong NSPopUpButton* layers;
    __strong NSStackView* textOptions;
    __strong NSMutableDictionary<NSNumber*, NSButton*>* buttons;
    __strong id inspectorKeyboard;
    QRect selection;
    bool visible = false;
};

MacCaptureBar::MacCaptureBar(QWidget* host,
                           const QVector<CaptureToolButton*>& tools,
                           QObject* parent)
  : QObject(parent), d(std::make_unique<Private>())
{
    d->widget = host;
    d->buttons = [NSMutableDictionary new];
    d->root = [FSGlassContainer new];
    d->root.spacing = 8;
    d->root.hover = ^(BOOL entered) { if (hoverChanged) hoverChanged(entered); };
    auto drawing = [NSMutableArray<NSView*> new];
    auto commands = [NSMutableArray<NSView*> new];
    auto overflow = [NSMenu new];
    // Keep the most-used tools visible; every configured tool is available.
    const QList<int> primary = {0, 2, 4, 5, 6, 15, 18, 19};
    for (auto* tool : tools) {
        const int type = tool->tool()->type();
        QPointer<CaptureToolButton> safe = tool;
        auto invoke = ^(id) {
            // Queue onto Qt so a close action cannot delete the AppKit target
            // in the middle of its own event dispatch.
            QTimer::singleShot(0, this, [safe]() {
                if (safe) emit safe->pressedButtonLeftClick(safe);
            });
        };
        bool command = type == 9 || type == 16 || type == 10 || type == 11 ||
                       type == 12 || type == 23;
        if (primary.contains(type) || command) {
            auto b = iconButton(toolName(tool), symbol(type), invoke);
            if (tool->tool()->isSelectable()) [b setButtonType:NSButtonTypePushOnPushOff];
            d->buttons[@(type)] = b;
            [(command ? commands : drawing) addObject:b];
        } else {
            auto item = [[NSMenuItem alloc] initWithTitle:toolName(tool)
                action:@selector(perform:) keyEquivalent:@""];
            auto target = [FSAction new]; target.block = invoke;
            item.target = target;
            objc_setAssociatedObject(item, @selector(perform:), target,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            item.image = [NSImage imageWithSystemSymbolName:symbol(type)
                                   accessibilityDescription:nil];
            [overflow addItem:item];
        }
    }
    if (overflow.numberOfItems) {
        auto more = iconButton(L(@"More tools", @"更多工具"), @"ellipsis", ^(id sender) {
            [overflow popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -6)
                                       inView:sender];
        });
        [drawing addObject:more];
    }
    auto settings = iconButton(L(@"Tool settings", @"工具设置"),
                                @"slider.horizontal.3", ^(id) { toggleInspector(); });
    if (ConfigHandler().showSidePanelButton()) [commands insertObject:settings atIndex:0];
    auto groups = stack(@[glass(stack(drawing, NSUserInterfaceLayoutOrientationHorizontal, 2)),
                           glass(stack(commands, NSUserInterfaceLayoutOrientationHorizontal, 2))],
                         NSUserInterfaceLayoutOrientationHorizontal, 12);
    d->root.contentView = groups;
    [groups layoutSubtreeIfNeeded];
    NSSize fitting = groups.fittingSize;
    [d->root setFrameSize:fitting];
    auto nativeHost = (__bridge NSView*)reinterpret_cast<void*>(host->winId());
    d->host = nativeHost;
    d->panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,fitting.width,fitting.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    d->panel.title = L(@"Annotation toolbar", @"标注工具栏");
    d->panel.floatingPanel = YES;
    d->panel.hidesOnDeactivate = NO;
    d->panel.becomesKeyOnlyIfNeeded = YES;
    d->panel.opaque = NO;
    d->panel.backgroundColor = NSColor.clearColor;
    d->panel.hasShadow = YES;
    d->panel.releasedWhenClosed = NO;
    d->panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    d->panel.contentView = d->root;
    d->root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [nativeHost.window addChildWindow:d->panel ordered:NSWindowAbove];
    [d->panel orderOut:nil];
    if (ConfigHandler().showHelp()) {
        auto title = label(L(@"Drag to select a capture region", @"拖动选择截图区域"), 17);
        auto detail = label(L(@"⌘C Copy  ·  ⌘S Save  ·  Space Tool settings  ·  Esc Cancel", @"⌘C 复制 · ⌘S 保存 · 空格 工具设置 · Esc 取消"), 12, YES);
        detail.preferredMaxLayoutWidth = 400;
        [detail.widthAnchor constraintEqualToConstant:400].active = YES;
        [title.widthAnchor constraintEqualToConstant:400].active = YES;
        auto hints = stack(@[title, detail], NSUserInterfaceLayoutOrientationVertical, 8);
        d->hint = glass(hints);
        d->hint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        QTimer::singleShot(0, this, [this]() {
            if (d->visible || !d->selection.isEmpty() || !d->host) return;
            auto host = d->host;
            const NSSize size = d->hint.contentView.fittingSize;
            NSRect local = NSMakeRect((NSWidth(host.bounds)-size.width)/2,
                                      (NSHeight(host.bounds)-size.height)/2, size.width, size.height);
            if (d->panel.parentWindow != host.window) [host.window addChildWindow:d->panel ordered:NSWindowAbove];
            d->panel.level = host.window.level + 1;
            d->panel.contentView = d->hint;
            d->panel.ignoresMouseEvents = YES;
            [d->panel setAccessibilityElement:NO];
            [d->panel setFrame:[host.window convertRectToScreen:[host convertRect:local toView:nil]] display:YES];
            [d->panel orderFront:nil];
        });
    }

    d->color = [NSColorWell new];
    d->color.color = nativeColor(ConfigHandler().drawColor());
    [d->color setAccessibilityLabel:L(@"Annotation color", @"标注颜色")];
    action(d->color, ^(NSColorWell* sender) {
        if (colorChanged) colorChanged(qtColor(sender.color));
    });
    d->thickness = [NSSlider sliderWithValue:ConfigHandler().drawThickness()
        minValue:1 maxValue:100 target:nil action:nil];
    [d->thickness setAccessibilityLabel:L(@"Tool size", @"工具尺寸")];
    d->sizeLabel = label(@"");
    action(d->thickness, ^(NSSlider* sender) {
        int value = (int)lround(sender.doubleValue);
        setThickness(value);
        if (thicknessChanged) thicknessChanged(value);
    });
    d->layers = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [d->layers setAccessibilityLabel:L(@"Annotations", @"标注图层")];
    action(d->layers, ^(NSPopUpButton* sender) {
        if (layerSelected) layerSelected((int)sender.indexOfSelectedItem - 1);
    });
    auto remove = button(L(@"Delete annotation", @"删除标注"), @"trash", ^(id) {
        if (deleteLayer) deleteLayer();
    });
    auto font = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [font addItemsWithTitles:NSFontManager.sharedFontManager.availableFontFamilies];
    [font selectItemWithTitle:ns(ConfigHandler().fontFamily())];
    action(font, ^(NSPopUpButton* sender) {
        ConfigHandler().setFontFamily(qs(sender.titleOfSelectedItem));
        if (fontChanged) fontChanged(qs(sender.titleOfSelectedItem));
    });
    auto formats = [NSMutableArray<NSView*> new];
    const QList<QPair<QString, NSString*>> styles = {{"bold", L(@"Bold", @"粗体")}, {"italic", L(@"Italic", @"斜体")}, {"underline", L(@"Underline", @"下划线")}, {"strike", L(@"Strikethrough", @"删除线")}};
    for (const auto& entry : styles) {
        const QString key = entry.first;
        auto toggle = [NSButton checkboxWithTitle:entry.second target:nil action:nil];
        action(toggle, ^(NSButton* sender) { if (textStyleChanged) textStyleChanged(key, sender.state == NSControlStateValueOn); });
        [formats addObject:toggle];
    }
    auto alignment = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [alignment addItemsWithTitles:@[L(@"Align left", @"左对齐"), L(@"Center", @"居中"), L(@"Align right", @"右对齐")]];
    action(alignment, ^(NSPopUpButton* sender) { if (textStyleChanged) textStyleChanged("alignment", (int)sender.indexOfSelectedItem); });
    d->textOptions = stack(@[font, stack(formats, NSUserInterfaceLayoutOrientationVertical, 6), alignment], NSUserInterfaceLayoutOrientationVertical, 8);
    d->textOptions.hidden = YES;
    auto moveUp = button(L(@"Move up", @"上移图层"), @"arrow.up", ^(id) { if (layerMoved) layerMoved(-1); });
    auto moveDown = button(L(@"Move down", @"下移图层"), @"arrow.down", ^(id) { if (layerMoved) layerMoved(1); });
    auto presets = [NSMutableArray<NSView*> new];
    for (const QColor preset : ConfigHandler().userColors()) {
        auto swatch = button(@"", nil, ^(id) {
            setColor(preset); if (colorChanged) colorChanged(preset);
        });
        swatch.toolTip = ns(preset.name());
        [swatch setAccessibilityLabel:ns(preset.name())];
        swatch.image = [NSImage imageWithSize:NSMakeSize(18,18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [nativeColor(preset) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1, 1)] fill]; return YES;
        }];
        swatch.imagePosition = NSImageOnly;
        [presets addObject:swatch];
    }
    auto presetRows = [NSMutableArray<NSView*> new];
    for (NSUInteger start = 0; start < presets.count; start += 5)
        [presetRows addObject:stack([presets subarrayWithRange:NSMakeRange(start, MIN(5, presets.count-start))], NSUserInterfaceLayoutOrientationHorizontal, 4)];
    auto inspectorContent = stack(@[
        label(L(@"Tool settings", @"工具设置"), 17),
        stack(presetRows, NSUserInterfaceLayoutOrientationVertical, 4),
        stack(@[label(L(@"Color", @"颜色")), d->color], NSUserInterfaceLayoutOrientationHorizontal),
        d->sizeLabel, d->thickness,
        d->textOptions,
        label(L(@"Annotations", @"标注图层")), d->layers,
        stack(@[moveUp, moveDown], NSUserInterfaceLayoutOrientationHorizontal, 8), remove,
        label(L(@"Space toggles this panel. Right-click opens it.",
                @"按空格键切换面板，右键打开面板。"), 11, YES)],
        NSUserInterfaceLayoutOrientationVertical);
    auto controller = [NSViewController new];
    controller.view = padded(inspectorContent, 20);
    [controller.view.widthAnchor constraintEqualToConstant:280].active = YES;
    d->inspector = [NSPopover new];
    d->inspector.behavior = NSPopoverBehaviorSemitransient;
    d->inspector.contentViewController = controller;
    d->inspectorKeyboard = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent*(NSEvent* event) {
            if (!d->inspector.shown) return event;
            const bool editing = [NSApp.keyWindow.firstResponder isKindOfClass:NSTextView.class];
            const bool plainSpace = event.keyCode == 49 && !editing &&
                !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption));
            if (event.keyCode != 53 && !plainSpace) return event;
            [d->inspector close];
            [d->host.window makeKeyWindow];
            [d->host.window makeFirstResponder:d->host];
            return nil;
        }];
    setThickness(ConfigHandler().drawThickness());
    setLayers({}, -1);
}

MacCaptureBar::~MacCaptureBar()
{
    [NSEvent removeMonitor:d->inspectorKeyboard];
    [d->inspector close];
    [d->panel.parentWindow removeChildWindow:d->panel];
    [d->panel close];
    [d->root removeFromSuperview];
    [d->hint removeFromSuperview];
    d->root.hover = nil;
}
void MacCaptureBar::setVisible(bool visible)
{
    d->visible = visible;
    if (visible) {
        if (d->panel.parentWindow != d->host.window) [d->host.window addChildWindow:d->panel ordered:NSWindowAbove];
        d->panel.level = d->host.window.level + 1;
        d->panel.contentView = d->root;
        d->panel.ignoresMouseEvents = NO;
        [d->panel setAccessibilityElement:YES];
        [d->panel orderFront:nil];
    } else {
        [d->panel orderOut:nil];
        [d->inspector close];
    }
}
bool MacCaptureBar::isVisible() const { return d->visible; }
bool MacCaptureBar::contains(const QPoint& p) const
{
    return d->widget && d->visible && d->barRect.contains(p);
}
void MacCaptureBar::setSelection(const QRect& selection)
{
    d->selection = selection;
    if (!d->widget) return;
    auto host = d->host;
    const CGFloat width = NSWidth(host.bounds), height = NSHeight(host.bounds);
    // Measure the horizontal layout each time so a narrow display does not
    // alternate between one and two rows as the selection moves.
    auto groups = (NSStackView*)d->root.contentView;
    groups.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    groups.alignment = NSLayoutAttributeCenterY;
    [groups layoutSubtreeIfNeeded];
    NSSize size = groups.fittingSize;
    if (size.width > width - 24) {
        groups.orientation = NSUserInterfaceLayoutOrientationVertical;
        groups.alignment = NSLayoutAttributeCenterX;
    }
    [groups layoutSubtreeIfNeeded];
    size = groups.fittingSize;
    CGFloat x = qBound(12.0, selection.center().x() - size.width / 2, qMax(12.0, width - size.width - 12));
    CGFloat y = selection.bottom() + 16;
    if (y + size.height > height - 12) y = selection.top() - size.height - 16;
    y = qBound(12.0, y, qMax(12.0, height - size.height - 12));
    d->barRect = QRect(qRound(x), qRound(y), qRound(size.width), qRound(size.height));
    const NSRect local = NSMakeRect(x, host.isFlipped ? y : height - y - size.height, size.width, size.height);
    [d->panel setFrame:[host.window convertRectToScreen:[host convertRect:local toView:nil]] display:YES];
}
void MacCaptureBar::setActiveTool(int type)
{
    d->textOptions.hidden = type != CaptureTool::TYPE_TEXT;
    for (NSNumber* key in d->buttons) {
        auto b = d->buttons[key];
        const BOOL selected = key.intValue == type;
        b.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        b.contentTintColor = selected ? NSColor.controlAccentColor : NSColor.labelColor;
        [b setAccessibilityValue:selected ? @1 : @0];
    }
}
void MacCaptureBar::setColor(const QColor& color) { d->color.color = nativeColor(color); }
void MacCaptureBar::setThickness(int size)
{
    d->thickness.maxValue = qMax(100, size);
    d->thickness.integerValue = size;
    d->sizeLabel.stringValue = [NSString stringWithFormat:L(@"Size: %d", @"尺寸：%d"), size];
}
void MacCaptureBar::setLayers(const QStringList& names, int selected)
{
    [d->layers removeAllItems];
    [d->layers addItemWithTitle:L(@"No annotation selected", @"未选择标注")];
    for (int i = 0; i < names.size(); ++i)
        [d->layers addItemWithTitle:[NSString stringWithFormat:@"%d · %@", i + 1, ns(names[i])]];
    [d->layers selectItemAtIndex:qBound(0, selected + 1, (int)names.size())];
}
void MacCaptureBar::toggleInspector()
{
    if (d->inspector.shown) [d->inspector close];
    else if (d->visible) {
        auto anchor = d->buttons.allValues.firstObject;
        // Anchor to the bar rather than an arbitrary screen coordinate.
        [d->inspector showRelativeToRect:d->root.bounds ofView:d->root preferredEdge:NSRectEdgeMaxY];
        (void)anchor;
    }
}

namespace {
__strong NSWindow* launcher;
}

void MacUI::installMenu()
{
    auto main = [NSMenu new];
    auto appRoot = [NSMenuItem new];
    auto app = [[NSMenu alloc] initWithTitle:@"Flameshoter"];
    auto add = ^(NSMenu* menu, NSString* title, NSString* key, void (^block)(id)) {
        auto item = [[NSMenuItem alloc] initWithTitle:title action:@selector(perform:) keyEquivalent:key];
        auto target = [FSAction new]; target.block = block; item.target = target;
        objc_setAssociatedObject(item, @selector(perform:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [menu addItem:item];
    };
    add(app, L(@"About Flameshoter", @"关于 Flameshoter"), @"", ^(id) { showAbout(); });
    [app addItem:NSMenuItem.separatorItem];
    add(app, L(@"Settings…", @"设置…"), @",", ^(id) { showPreferences(); });
    [app addItem:NSMenuItem.separatorItem];
    add(app, L(@"Quit Flameshoter", @"退出 Flameshoter"), @"q", ^(id) { qApp->quit(); });
    appRoot.submenu = app; [main addItem:appRoot];
    auto windowRoot = [[NSMenuItem alloc] initWithTitle:L(@"Window", @"窗口") action:nil keyEquivalent:@""];
    auto windowMenu = [[NSMenu alloc] initWithTitle:windowRoot.title];
    add(windowMenu, L(@"Capture window", @"截图窗口"), @"n", ^(id) { showLauncher(); });
    add(windowMenu, L(@"Try annotation tools", @"试用标注工具"), @"", ^(id) { showDemo(); });
    auto close = [[NSMenuItem alloc] initWithTitle:L(@"Close Window", @"关闭窗口") action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenu addItem:close];
    windowRoot.submenu = windowMenu; [main addItem:windowRoot];
    NSApp.mainMenu = main;
}

void MacUI::showLauncher()
{
    installMenu();
    if (launcher) { activate(launcher); return; }
    auto title = label(@"Flameshoter", 30);
    title.font = [NSFont systemFontOfSize:30 weight:NSFontWeightSemibold];
    auto delay = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [delay addItemsWithTitles:@[L(@"No delay", @"无延迟"), L(@"3 seconds", @"3 秒"),
                               L(@"5 seconds", @"5 秒"), L(@"10 seconds", @"10 秒")]];
    [delay setAccessibilityLabel:L(@"Capture delay", @"截图延迟")];
    auto capture = button(L(@"Capture region", @"截取区域"), @"viewfinder", ^(id) {
        [launcher orderOut:nil];
        const int seconds[] = {0,3,5,10};
        int milliseconds = seconds[delay.indexOfSelectedItem] * 1000 + 180;
        QTimer::singleShot(milliseconds, Flameshot::instance(), [] { Flameshot::instance()->gui(); });
    });
    capture.keyEquivalent = @"\r";
    capture.controlSize = NSControlSizeLarge;
    auto settings = button(L(@"Settings…", @"设置…"), @"gearshape", ^(id) { showPreferences(); });
    auto content = stack(@[title,
        label(L(@"Capture. Annotate. Share.", @"截图、标注，轻松分享。"), 17, YES),
        label(L(@"Drag to select a region, then annotate with the floating toolbar. Your captures stay on your Mac.",
                @"拖动选择截图区域，再用浮动工具栏进行标注。截图保存在你的 Mac 上。"), 13, YES),
        stack(@[label(L(@"Delay", @"延迟")), delay], NSUserInterfaceLayoutOrientationHorizontal),
        stack(@[capture, settings], NSUserInterfaceLayoutOrientationHorizontal),
        button(L(@"Try annotation tools", @"试用标注工具"), @"pencil.tip", ^(id) { showDemo(); }),
        label(L(@"Press ⌘⇧X anywhere to start a capture.\nFlameshoter stays in the menu bar when this window closes.",
                @"默认可随时按 ⌘⇧X 开始截图。\n关闭此窗口后，Flameshoter 会继续驻留菜单栏。"), 12, YES)],
        NSUserInterfaceLayoutOrientationVertical, 20);
    launcher = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,460,360)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    launcher.releasedWhenClosed = NO;
    launcher.title = @"Flameshoter";
    launcher.contentView = padded(content, 32);
    activate(launcher);
}

void MacUI::showAbout()
{
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: @"Flameshoter",
        NSAboutPanelOptionApplicationVersion: ns(QCoreApplication::applicationVersion()),
        NSAboutPanelOptionVersion: @"Based on Flameshot • GPL-3.0-or-later",
        NSAboutPanelOptionCredits: [[NSAttributedString alloc] initWithString:L(
            @"Native Liquid Glass interface.\nBuilt on Flameshot by Alejandro Sirgo Rica and contributors.\nhttps://github.com/Word2VecT/flameshoter",
            @"原生液态玻璃界面。\n基于 Alejandro Sirgo Rica 及贡献者开发的 Flameshot。\nhttps://github.com/Word2VecT/flameshoter")]}];
    [NSApp activateIgnoringOtherApps:YES];
}
bool MacUI::confirmDiscard()
{
    auto alert = [NSAlert new];
    alert.messageText = L(@"Discard this capture?", @"丢弃这张截图？");
    alert.informativeText = L(@"Unsaved annotations will be lost.", @"未保存的标注将会丢失。");
    [alert addButtonWithTitle:L(@"Keep Editing", @"继续编辑")];
    [alert addButtonWithTitle:L(@"Discard", @"丢弃")];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

void MacCaptureBar::showInspector()
{
    if (!d->inspector.shown) toggleInspector();
}


bool MacUI::ensureScreenCaptureAccess()
{
    if (!qEnvironmentVariableIsEmpty("FLAMESHOTER_TEST_IMAGE") || CGPreflightScreenCaptureAccess()) return true;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    CGRequestScreenCaptureAccess();
    if (CGPreflightScreenCaptureAccess()) return true;
    auto alert = [NSAlert new];
    alert.messageText = L(@"Allow screen recording to take screenshots", @"允许屏幕录制以使用截图功能");
    alert.informativeText = L(@"Enable Flameshoter in System Settings, then choose Restart. If the app is missing, use + to add Flameshoter from Applications. Closing a window leaves the menu bar process running. If access is already enabled but still fails, choose Repair Authorization.", @"请先在系统设置中允许 Flameshoter，再点“重新启动”。若列表中没有此应用，请点击 +，添加“应用程序”中的 Flameshoter。关闭窗口不会退出菜单栏后台进程；若开关已开启仍无效，请点“修复授权…”。");
    [alert addButtonWithTitle:L(@"Open System Settings", @"打开系统设置")];
    [alert addButtonWithTitle:L(@"Restart", @"重新启动")];
    [alert addButtonWithTitle:L(@"Repair Authorization…", @"修复授权…")];
    [alert addButtonWithTitle:L(@"Later", @"稍后")];
    const auto response = [alert runModal];
    if (response == NSAlertFirstButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    else if (response == NSAlertSecondButtonReturn) restartApp();
    else if (response == NSAlertThirdButtonReturn) repairScreenCaptureAccess();
    return false;
}

void MacUI::restartApp()
{
    // Wait for the whole menu-bar process to exit before LaunchServices opens
    // the installed bundle, so the new instance cannot be forwarded to the old one.
    const QString script = QString::fromUtf8(R"RELAUNCH(
i=0
while /bin/kill -0 "$1" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge 100 ]; then exit 1; fi
    /bin/sleep 0.2
done
exec /usr/bin/open -n -a "$2" --args "$3"
)RELAUNCH");
    if (!QProcess::startDetached("/bin/sh", {"-c", script, "flameshoter-relaunch",
            QString::number(QCoreApplication::applicationPid()),
            qs(NSBundle.mainBundle.bundlePath), "launcher"})) {
        auto alert = [NSAlert new];
        alert.messageText = L(@"Unable to restart Flameshoter", @"无法重新启动 Flameshoter");
        alert.informativeText = L(@"Quit Flameshoter from its menu, then open it from Applications.", @"请从菜单退出 Flameshoter，再从“应用程序”重新打开。");
        [alert runModal]; return;
    }
    QTimer::singleShot(0, qApp, [] { qApp->quit(); });
}

void MacUI::repairScreenCaptureAccess()
{
    auto alert = [NSAlert new];
    alert.messageText = L(@"Register this version's screen recording authorization again?", @"重新登记当前版本的屏幕录制授权？");
    alert.informativeText = L(@"This removes only Flameshoter's old Screen Recording record and restarts the app. Click Capture region in the reopened window to request access again. If macOS does not list the app, use + in Screen Recording settings to add Flameshoter from Applications. Other apps and permissions are unaffected.", @"本操作只清除 Flameshoter 的旧录屏授权，并彻底重启。重新打开后点击“截取区域”申请授权；若系统列表中没有此应用，请点击 +，添加“应用程序”中的 Flameshoter。不会更改其他应用的权限。");
    [alert addButtonWithTitle:L(@"Cancel", @"取消")];
    [alert addButtonWithTitle:L(@"Repair and Restart", @"修复并重新启动")];
    if ([alert runModal] != NSAlertSecondButtonReturn) return;
    const QString bundle = qs(NSBundle.mainBundle.bundleIdentifier);
    if (bundle != "io.github.Word2VecT.flameshoter") return;
    QProcess reset;
    reset.start("/usr/bin/tccutil", {"reset", "ScreenCapture", bundle});
    if (!reset.waitForFinished(5000) || reset.exitStatus() != QProcess::NormalExit || reset.exitCode() != 0) {
        auto failure = [NSAlert new];
        failure.messageText = L(@"Authorization could not be refreshed", @"无法刷新授权记录");
        failure.informativeText = L(@"In Screen Recording settings, remove Flameshoter using the minus button, then add the app from Applications again.", @"请在系统的屏幕录制设置中，用减号移除 Flameshoter，再从“应用程序”中重新添加。");
        [failure runModal]; return;
    }
    restartApp();
}


void MacUI::showDemo()
{
    [launcher orderOut:nil];
    const QByteArray previous = qgetenv("FLAMESHOTER_TEST_IMAGE");
    const QString path = QCoreApplication::applicationDirPath() + "/../Resources/flameshoter-demo.png";
    qputenv("FLAMESHOTER_TEST_IMAGE", path.toUtf8());
    Flameshot::instance()->gui();
    if (previous.isNull()) qunsetenv("FLAMESHOTER_TEST_IMAGE");
    else qputenv("FLAMESHOTER_TEST_IMAGE", previous);
}

QColor MacUI::systemAccentColor()
{
    return qtColor(NSColor.controlAccentColor);
}
