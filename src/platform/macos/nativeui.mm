// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Flameshoter contributors
#include "nativeui.h"
#include "core/flameshot.h"
#include "utils/confighandler.h"
#include "widgets/capture/capturetoolbutton.h"

#include <QApplication>
#include <QLocale>
#include <QPointer>
#include <QTimer>
#include <QWidget>
#import <AppKit/AppKit.h>
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
    __strong NSPopover* inspector;
    __strong NSColorWell* color;
    __strong NSSlider* thickness;
    __strong NSTextField* sizeLabel;
    __strong NSPopUpButton* layers;
    __strong NSMutableDictionary<NSNumber*, NSButton*>* buttons;
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
    [commands insertObject:settings atIndex:0];
    auto groups = stack(@[glass(stack(drawing, NSUserInterfaceLayoutOrientationHorizontal, 2)),
                           glass(stack(commands, NSUserInterfaceLayoutOrientationHorizontal, 2))],
                         NSUserInterfaceLayoutOrientationHorizontal, 12);
    d->root.contentView = groups;
    [groups layoutSubtreeIfNeeded];
    NSSize fitting = groups.fittingSize;
    [d->root setFrameSize:fitting];
    auto nativeHost = (__bridge NSView*)reinterpret_cast<void*>(host->winId());
    [nativeHost addSubview:d->root];
    d->root.hidden = YES;

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
    [font addItemsWithTitles:@[@"System", @"Helvetica Neue", @"PingFang SC", @"Menlo"]];
    [font selectItemWithTitle:ns(ConfigHandler().fontFamily())];
    action(font, ^(NSPopUpButton* sender) {
        ConfigHandler().setFontFamily(qs(sender.titleOfSelectedItem));
    });
    auto inspectorContent = stack(@[
        label(L(@"Tool settings", @"工具设置"), 17),
        stack(@[label(L(@"Color", @"颜色")), d->color], NSUserInterfaceLayoutOrientationHorizontal),
        d->sizeLabel, d->thickness,
        label(L(@"Font for new text", @"新文字的字体")), font,
        label(L(@"Annotations", @"标注图层")), d->layers, remove,
        label(L(@"Space toggles this panel. Right-click opens it.",
                @"按空格键切换面板，右键打开面板。"), 11, YES)],
        NSUserInterfaceLayoutOrientationVertical);
    auto controller = [NSViewController new];
    controller.view = padded(inspectorContent, 20);
    [controller.view.widthAnchor constraintEqualToConstant:280].active = YES;
    d->inspector = [NSPopover new];
    d->inspector.behavior = NSPopoverBehaviorSemitransient;
    d->inspector.contentViewController = controller;
    setThickness(ConfigHandler().drawThickness());
    setLayers({}, -1);
}

MacCaptureBar::~MacCaptureBar()
{
    [d->inspector close];
    [d->root removeFromSuperview];
    d->root.hover = nil;
}
void MacCaptureBar::setVisible(bool visible)
{
    d->visible = visible;
    d->root.hidden = !visible;
    if (!visible) [d->inspector close];
}
bool MacCaptureBar::isVisible() const { return d->visible; }
bool MacCaptureBar::contains(const QPoint& p) const
{
    if (!d->widget || !d->visible) return false;
    const NSRect frame = d->root.frame;
    const auto host = d->root.superview;
    const CGFloat y = host.isFlipped ? p.y() : NSHeight(host.bounds) - p.y();
    return NSPointInRect(NSMakePoint(p.x(), y), frame);
}
void MacCaptureBar::setSelection(const QRect& selection)
{
    d->selection = selection;
    if (!d->widget) return;
    auto host = d->root.superview;
    const CGFloat width = NSWidth(host.bounds), height = NSHeight(host.bounds);
    NSSize size = d->root.contentView.fittingSize;
    CGFloat scale = qMin(1.0, (width - 24.0) / qMax(1.0, size.width));
    // On small displays use two rows, preserving normal control hit targets.
    auto groups = (NSStackView*)d->root.contentView;
    groups.orientation = scale < 1 ? NSUserInterfaceLayoutOrientationVertical
                                  : NSUserInterfaceLayoutOrientationHorizontal;
    groups.alignment = NSLayoutAttributeCenterX;
    if (scale == 1) groups.alignment = NSLayoutAttributeCenterY;
    [groups layoutSubtreeIfNeeded];
    size = groups.fittingSize;
    CGFloat x = qBound(12.0, selection.center().x() - size.width / 2, qMax(12.0, width - size.width - 12));
    CGFloat y = selection.bottom() + 16;
    if (y + size.height > height - 12) y = selection.top() - size.height - 16;
    y = qBound(12.0, y, qMax(12.0, height - size.height - 12));
    d->root.frame = NSMakeRect(x, host.isFlipped ? y : height - y - size.height,
                               size.width, size.height);
}
void MacCaptureBar::setActiveTool(int type)
{
    for (NSNumber* key in d->buttons) {
        auto b = d->buttons[key];
        b.contentTintColor = key.intValue == type ? NSColor.controlAccentColor : NSColor.labelColor;
        [b setAccessibilityValue:key.intValue == type ? @1 : @0];
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
NSView* check(NSString* en, NSString* zh, const char* key)
{
    QString option = QString::fromUtf8(key);
    auto b = [NSButton checkboxWithTitle:L(en, zh) target:nil action:nil];
    b.state = ConfigHandler().value(option).toBool() ? NSControlStateValueOn : NSControlStateValueOff;
    action(b, ^(NSButton* sender) { ConfigHandler().setValue(option, sender.state == NSControlStateValueOn); });
    return b;
}
NSView* textOption(NSString* en, NSString* zh, const char* key)
{
    QString option = QString::fromUtf8(key);
    auto field = [NSTextField textFieldWithString:ns(ConfigHandler().value(option).toString())];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.widthAnchor constraintEqualToConstant:320].active = YES;
    [field setAccessibilityLabel:L(en, zh)];
    action(field, ^(NSTextField* sender) { ConfigHandler().setValue(option, qs(sender.stringValue)); });
    return stack(@[label(L(en, zh)), field], NSUserInterfaceLayoutOrientationVertical, 6);
}
NSView* sliderOption(NSString* en, NSString* zh, const char* key, int low, int high)
{
    QString option = QString::fromUtf8(key);
    auto title = label([NSString stringWithFormat:@"%@: %d", L(en, zh), ConfigHandler().value(option).toInt()]);
    auto slider = [NSSlider sliderWithValue:ConfigHandler().value(option).toInt()
                                 minValue:low maxValue:high target:nil action:nil];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider.widthAnchor constraintEqualToConstant:320].active = YES;
    [slider setAccessibilityLabel:L(en, zh)];
    action(slider, ^(NSSlider* sender) {
        int value = (int)lround(sender.doubleValue);
        ConfigHandler().setValue(option, value);
        title.stringValue = [NSString stringWithFormat:@"%@: %d", L(en, zh), value];
    });
    return stack(@[title, slider], NSUserInterfaceLayoutOrientationVertical, 6);
}
NSTabViewItem* page(NSString* title, NSString* image, NSArray<NSView*>* controls)
{
    auto content = stack(controls, NSUserInterfaceLayoutOrientationVertical, 16);
    auto controller = [NSViewController new];
    controller.view = padded(content, 28);
    auto item = [NSTabViewItem tabViewItemWithViewController:controller];
    item.label = title;
    item.image = [NSImage imageWithSystemSymbolName:image accessibilityDescription:title];
    return item;
}
__strong NSWindow* preferences;
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
    auto close = [[NSMenuItem alloc] initWithTitle:L(@"Close Window", @"关闭窗口") action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenu addItem:close];
    windowRoot.submenu = windowMenu; [main addItem:windowRoot];
    NSApp.mainMenu = main;
}

void MacUI::showPreferences()
{
    installMenu();
    if (preferences) { activate(preferences); return; }
    auto tabs = [NSTabViewController new];
    tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    auto language = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [language addItemsWithTitles:@[L(@"Follow System", @"跟随系统"), @"简体中文", @"English"]];
    auto current = ConfigHandler().uiLanguage();
    [language selectItemAtIndex:current.startsWith("zh") ? 1 : current == "en" ? 2 : 0];
    [language setAccessibilityLabel:L(@"Interface language", @"界面语言")];
    action(language, ^(NSPopUpButton* sender) {
        ConfigHandler().setUiLanguage(sender.indexOfSelectedItem == 1 ? "zh_CN" :
                                     sender.indexOfSelectedItem == 2 ? "en" : "auto");
        auto alert = [NSAlert new];
        alert.messageText = L(@"Language updated", @"语言已更新");
        alert.informativeText = L(@"Restart Flameshoter to update all menus and windows.",
                                  @"重新启动 Flameshoter 后，所有菜单和窗口将使用新语言。");
        [alert addButtonWithTitle:L(@"OK", @"好")];
        [alert beginSheetModalForWindow:preferences completionHandler:nil];
    });
    auto directory = button(L(@"Choose save folder…", @"选择保存文件夹…"), @"folder", ^(id) {
        auto panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories = YES; panel.canChooseFiles = NO;
        panel.canCreateDirectories = YES; panel.allowsMultipleSelection = NO;
        [panel beginSheetModalForWindow:preferences completionHandler:^(NSModalResponse result) {
            if (result == NSModalResponseOK) ConfigHandler().setSavePath(qs(panel.URL.path));
        }];
    });
    auto permissions = button(L(@"Screen Recording permissions…", @"屏幕录制权限…"),
        @"lock.shield", ^(id) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
                @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        });
    [tabs addTabViewItem:page(L(@"General", @"通用"), @"gearshape", @[
        label(L(@"Interface language", @"界面语言")), language,
        label(L(@"Uses the system appearance, accent color, contrast, transparency and motion preferences.",
                @"外观、强调色、对比度、透明度和动态效果均遵循系统设置。"), 12, YES),
        check(@"Show capture instructions", @"显示截图操作提示", "showHelp"),
        check(@"Show desktop notifications", @"显示桌面通知", "showDesktopNotification"),
        check(@"Confirm before discarding a capture", @"丢弃截图前询问", "showQuitPrompt"),
        permissions])];
    [tabs addTabViewItem:page(L(@"Capture", @"截图"), @"viewfinder", @[
        directory, textOption(@"Filename pattern", @"文件名格式", "filenamePattern"),
        check(@"Save to the chosen folder without asking", @"直接保存到所选文件夹", "savePathFixed"),
        check(@"Also save after copying", @"复制后同时保存", "saveAfterCopy"),
        check(@"Copy the path after saving", @"保存后复制路径", "copyPathAfterSave"),
        check(@"Remember the last capture region", @"记住上次截图区域", "saveLastRegion"),
        check(@"Double-click to copy", @"双击复制截图", "copyOnDoubleClick"),
        check(@"Show magnifier", @"显示放大镜", "showMagnifier"),
        sliderOption(@"Outside selection dimming", @"选区外遮罩深度", "contrastOpacity", 0, 255)])];
    [tabs addTabViewItem:page(L(@"Annotation", @"标注"), @"pencil.tip", @[
        sliderOption(@"Stroke width", @"线条宽度", "drawThickness", 1, 30),
        sliderOption(@"Text size", @"文字字号", "drawFontSize", 8, 96),
        sliderOption(@"Pixelation size", @"马赛克尺寸", "drawPixelateSize", 1, 50),
        sliderOption(@"Marker width", @"荧光笔宽度", "drawMarkerSize", 1, 60),
        check(@"Reverse arrow direction", @"反转箭头方向", "reverseArrow"),
        check(@"Outline numbered annotations", @"为序号标注绘制轮廓", "drawCircleCounterOutline"),
        label(L(@"During capture, open Tool Settings to change color, size, font or select an annotation.",
                @"截图时打开“工具设置”，即可调整颜色、尺寸、字体或选择标注图层。"), 12, YES)])];
    auto shortcuts = [NSMutableArray<NSView*> new];
    [shortcuts addObject:label(L(@"Capture shortcut", @"截图快捷键"), 17)];
    auto shortcut = [NSTextField textFieldWithString:ns(ConfigHandler().shortcut("TAKE_SCREENSHOT"))];
    [shortcut setAccessibilityLabel:L(@"Global capture shortcut", @"全局截图快捷键")];
    action(shortcut, ^(NSTextField* sender) {
        if (!ConfigHandler().setShortcut("TAKE_SCREENSHOT", qs(sender.stringValue))) {
            NSBeep();
            sender.stringValue = ns(ConfigHandler().shortcut("TAKE_SCREENSHOT"));
        }
    });
    [shortcuts addObject:shortcut];
    [shortcuts addObject:label(L(@"Use Qt shortcut notation, for example Ctrl+Shift+X (⌘⇧X on Mac). Restart after changing the global shortcut.",
        @"使用 Qt 快捷键格式，例如 Ctrl+Shift+X（Mac 上对应 ⌘⇧X）。修改全局快捷键后请重启应用。"), 12, YES)];
    [shortcuts addObject:label(L(@"⌘C  Copy    ⌘S  Save    ⌘Z  Undo    ⇧⌘Z  Redo\nP  Pencil    A  Arrow    R  Rectangle    T  Text\nB  Pixelate    Space  Tool settings    Esc  Cancel",
        @"⌘C 复制    ⌘S 保存    ⌘Z 撤销    ⇧⌘Z 重做\nP 画笔    A 箭头    R 矩形    T 文字\nB 马赛克    空格 工具设置    Esc 取消"))];
    [tabs addTabViewItem:page(L(@"Shortcuts", @"快捷键"), @"keyboard", shortcuts)];
    preferences = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    preferences.releasedWhenClosed = NO;
    preferences.title = L(@"Flameshoter Settings", @"Flameshoter 设置");
    preferences.contentViewController = tabs;
    activate(preferences);
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
