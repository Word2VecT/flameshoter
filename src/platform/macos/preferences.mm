// SPDX-License-Identifier: GPL-3.0-or-later
#include "nativeui.h"
#include "tools/toolfactory.h"
#include "utils/confighandler.h"
#include "utils/filenamehandler.h"
#include "utils/pathinfo.h"
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QKeySequence>
#include <QLocale>
#include <QMetaEnum>
#include <QSaveFile>
#include <QSettings>
#include <QTimer>
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <objc/runtime.h>

namespace {
NSString* S(const QString& s) { return s.toNSString(); }
QString Q(NSString* s) { return QString::fromNSString(s ?: @""); }
NSString* T(NSString* en, NSString* zh)
{
    const auto lang = ConfigHandler().uiLanguage();
    return lang.startsWith("zh") || (lang == "auto" && QLocale::system().language() == QLocale::Chinese) ? zh : en;
}
__strong NSWindow* settingsWindow;
void message(NSString* title, NSString* detail)
{
    auto alert = [NSAlert new]; alert.messageText = title; alert.informativeText = detail;
    [alert addButtonWithTitle:T(@"OK", @"好")];
    [alert beginSheetModalForWindow:settingsWindow completionHandler:nil];
}
}

@interface FSPrefAction : NSObject<NSTextFieldDelegate>
@property(copy) void (^block)(id);
- (void)perform:(id)sender;
@end
@implementation FSPrefAction
- (void)perform:(id)sender { if (_block) _block(sender); }
- (void)controlTextDidEndEditing:(NSNotification*)n { [self perform:n.object]; }
@end

@interface FSSettingsDocument : NSView
@end
@implementation FSSettingsDocument
- (BOOL)isFlipped { return YES; }
@end

@interface FSShortcutRecorder : NSButton {
@public
    QString binding;
    std::function<bool(const QString&)> save;
    BOOL recording;
}
- (void)record:(id)sender;
- (void)refresh;
@end
@implementation FSShortcutRecorder
- (BOOL)acceptsFirstResponder { return YES; }
- (void)record:(id)sender
{
    recording = YES; self.title = T(@"Press shortcut…", @"按下快捷键…");
    [self.window makeFirstResponder:self];
}
- (void)refresh
{
    self.title = binding.isEmpty() ? T(@"Not assigned", @"未设置") :
        S(QKeySequence(binding).toString(QKeySequence::NativeText));
}
- (BOOL)performKeyEquivalent:(NSEvent*)event
{
    if (recording) { [self keyDown:event]; return YES; }
    return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent*)event
{
    if (!recording) { [super keyDown:event]; return; }
    if (event.keyCode == 53) { recording = NO; [self refresh]; return; }
    int key = 0;
    switch (event.keyCode) {
        case 36: key = Qt::Key_Return; break;
        case 48: key = Qt::Key_Tab; break;
        case 49: key = Qt::Key_Space; break;
        case 51: key = Qt::Key_Backspace; break;
        case 117: key = Qt::Key_Delete; break;
        case 123: key = Qt::Key_Left; break;
        case 124: key = Qt::Key_Right; break;
        case 125: key = Qt::Key_Down; break;
        case 126: key = Qt::Key_Up; break;
        default: {
            auto chars = Q(event.charactersIgnoringModifiers).toUpper();
            if (chars.size() == 1) {
                auto ch = chars[0].unicode();
                key = ch >= NSF1FunctionKey && ch <= NSF35FunctionKey ?
                    Qt::Key_F1 + ch - NSF1FunctionKey : ch;
            }
        }
    }
    if (!key) { NSBeep(); return; }
    const auto flags = event.modifierFlags;
    if (flags & NSEventModifierFlagCommand) key |= Qt::CTRL;
    if (flags & NSEventModifierFlagControl) key |= Qt::META;
    if (flags & NSEventModifierFlagOption) key |= Qt::ALT;
    if (flags & NSEventModifierFlagShift) key |= Qt::SHIFT;
    const QString proposed = QKeySequence(key).toString(QKeySequence::PortableText);
    recording = NO;
    if (save(proposed)) binding = proposed;
    else message(T(@"Shortcut unavailable", @"快捷键不可用"),
        T(@"This shortcut conflicts with another action. Choose a different combination.",
          @"此快捷键与其他操作冲突，请使用其他组合键。"));
    [self refresh];
}
@end

namespace {
void on(NSControl* control, void (^block)(id))
{
    auto target = [FSPrefAction new]; target.block = block;
    control.target = target; control.action = @selector(perform:);
    if ([control isKindOfClass:NSTextField.class]) ((NSTextField*)control).delegate = target;
    objc_setAssociatedObject(control, @selector(perform:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
NSTextField* text(NSString* value, BOOL secondary = NO)
{
    auto t = [NSTextField wrappingLabelWithString:value];
    t.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    t.lineBreakMode = NSLineBreakByWordWrapping;
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [t setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}
NSStackView* column(NSArray<NSView*>* controls, CGFloat spacing = 14)
{
    auto s = [NSStackView stackViewWithViews:controls];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading; s.spacing = spacing;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}
NSStackView* row(NSArray<NSView*>* controls, BOOL fill = NO)
{
    auto s = [NSStackView stackViewWithViews:controls]; s.spacing = 12;
    s.alignment = NSLayoutAttributeCenterY;
    if (fill) s.distribution = NSStackViewDistributionFill;
    return s;
}
NSView* heading(NSString* en, NSString* zh)
{
    auto t = text(T(en, zh)); t.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    return t;
}
NSButton* push(NSString* title, void (^block)(id))
{
    auto b = [NSButton buttonWithTitle:title target:nil action:nil];
    b.bezelStyle = NSBezelStyleRounded; on(b, block); return b;
}
NSView* boolean(const char* key, NSString* en, NSString* zh, BOOL inverted = NO)
{
    QString option = QString::fromUtf8(key);
    auto b = [NSButton checkboxWithTitle:T(en, zh) target:nil action:nil];
    b.state = (ConfigHandler().value(option).toBool() != inverted) ? NSControlStateValueOn : NSControlStateValueOff;
    b.identifier = S(option);
    on(b, ^(NSButton* sender) {
        const bool value = (sender.state == NSControlStateValueOn) != inverted;
        if (option == "startupLaunch") {
            ConfigHandler().setStartupLaunch(value);
            sender.state = ConfigHandler().startupLaunch() ? NSControlStateValueOn : NSControlStateValueOff;
        } else ConfigHandler().setValue(option, value);
    });
    return b;
}
NSView* integer(const char* key, NSString* en, NSString* zh, int low, int high, int displayOffset = 0)
{
    QString option = QString::fromUtf8(key);
    auto field = [NSTextField textFieldWithString:S(QString::number(ConfigHandler().value(option).toInt() + displayOffset))];
    auto formatter = [NSNumberFormatter new]; formatter.minimum = @(low + displayOffset);
    formatter.maximum = @(high + displayOffset); formatter.allowsFloats = NO;
    field.formatter = formatter; [field.widthAnchor constraintEqualToConstant:84].active = YES;
    [field setAccessibilityLabel:T(en, zh)];
    on(field, ^(NSTextField* sender) {
        int value = qBound(low, (int)sender.integerValue - displayOffset, high);
        ConfigHandler().setValue(option, value);
        sender.integerValue = value + displayOffset;
    });
    auto title = text(T(en, zh));
    return row(@[title, field], YES);
}
NSView* color(const char* key, NSString* en, NSString* zh)
{
    QString option = QString::fromUtf8(key); QColor initial = ConfigHandler().value(option).value<QColor>();
    auto well = [NSColorWell new];
    well.color = [NSColor colorWithSRGBRed:initial.redF() green:initial.greenF() blue:initial.blueF() alpha:initial.alphaF()];
    [well setAccessibilityLabel:T(en, zh)];
    on(well, ^(NSColorWell* sender) {
        auto c = [sender.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        ConfigHandler().setValue(option, QColor::fromRgbF(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent));
    });
    auto title = text(T(en, zh));
    return row(@[title, well], YES);
}
NSView* popup(const char* key, NSString* en, NSString* zh, NSArray<NSString*>* names, const QStringList& values = {})
{
    QString option = QString::fromUtf8(key); const QStringList choices = values;
    auto picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [picker addItemsWithTitles:names];
    int index = choices.isEmpty() ? ConfigHandler().value(option).toInt() : choices.indexOf(ConfigHandler().value(option).toString());
    [picker selectItemAtIndex:qMax(0, index)]; [picker setAccessibilityLabel:T(en, zh)];
    on(picker, ^(NSPopUpButton* sender) {
        if (choices.isEmpty()) ConfigHandler().setValue(option, (int)sender.indexOfSelectedItem);
        else ConfigHandler().setValue(option, choices[(int)sender.indexOfSelectedItem]);
    });
    return column(@[text(T(en, zh)), picker], 6);
}
NSTabViewItem* tab(NSString* title, NSString* image, NSArray<NSView*>* controls)
{
    auto content = column(controls);
    auto document = [FSSettingsDocument new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:content];
    [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:28].active = YES;
    [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-28].active = YES;
    [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:28].active = YES;
    [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-28].active = YES;
    for (NSView* control in controls) {
        if ([control isKindOfClass:NSStackView.class] || [control isKindOfClass:NSTextField.class])
            [control.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
        else [control.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor].active = YES;
    }
    auto scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,660,560)];
    scroll.hasVerticalScroller = YES; scroll.drawsBackground = NO;
    scroll.hasHorizontalScroller = NO;
    scroll.documentView = document;
    [NSLayoutConstraint activateConstraints:@[
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor]]];
    auto controller = [NSViewController new]; controller.view = scroll;
    auto item = [NSTabViewItem tabViewItemWithViewController:controller]; item.label = title;
    item.image = [NSImage imageWithSystemSymbolName:image accessibilityDescription:title];
    return item;
}
void rebuild()
{
    NSInteger selected = ((NSTabViewController*)settingsWindow.contentViewController).selectedTabViewItemIndex;
    [settingsWindow orderOut:nil]; settingsWindow = nil;
    MacUI::showPreferences();
    ((NSTabViewController*)settingsWindow.contentViewController).selectedTabViewItemIndex = selected;
}
NSView* fileControls()
{
    auto exportButton = push(T(@"Export…", @"导出…"), ^(id) {
        auto panel = [NSSavePanel savePanel]; panel.nameFieldStringValue = @"flameshoter.ini";
        [panel beginSheetModalForWindow:settingsWindow completionHandler:^(NSModalResponse response) {
            if (response != NSModalResponseOK) return;
            QFile input(ConfigHandler().configFilePath());
            QSaveFile output(Q(panel.URL.path));
            if (!input.open(QIODevice::ReadOnly) || !output.open(QIODevice::WriteOnly) ||
                output.write(input.readAll()) < 0 || !output.commit())
                message(T(@"Export failed", @"导出失败"), T(@"The configuration could not be saved.", @"无法保存配置文件。"));
        }];
    });
    auto importButton = push(T(@"Import…", @"导入…"), ^(id) {
        auto panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = NO;
        [panel beginSheetModalForWindow:settingsWindow completionHandler:^(NSModalResponse response) {
            if (response != NSModalResponseOK) return;
            QSettings imported(Q(panel.URL.path), QSettings::IniFormat);
            bool valid = imported.status() == QSettings::NoError;
            for (const QString& key : imported.childKeys())
                valid &= ConfigHandler::validSetting("General", key, imported.value(key));
            for (const QString& group : imported.childGroups()) {
                imported.beginGroup(group);
                for (const QString& key : imported.childKeys())
                    valid &= ConfigHandler::validSetting(group, key, imported.value(key));
                imported.endGroup();
            }
            if (!valid || (imported.childGroups().isEmpty() && imported.childKeys().isEmpty())) {
                message(T(@"Invalid configuration", @"配置无效"), T(@"Check the file's options and values before importing it.", @"文件含有不支持的选项或无效值，请检查后重新导入。")); return;
            }
            QFile input(Q(panel.URL.path)); QSaveFile output(ConfigHandler().configFilePath());
            if (input.open(QIODevice::ReadOnly) && output.open(QIODevice::WriteOnly) &&
                output.write(input.readAll()) >= 0 && output.commit()) {
                ConfigHandler().setErrorState(false); rebuild();
            } else message(T(@"Import failed", @"导入失败"), T(@"The configuration could not be written.", @"无法写入配置文件。"));
        }];
    });
    auto reset = push(T(@"Restore defaults…", @"恢复默认设置…"), ^(id) {
        auto alert = [NSAlert new]; alert.messageText = T(@"Restore all defaults?", @"恢复所有默认设置？");
        alert.informativeText = T(@"Your custom settings and shortcuts will be replaced.", @"自定义设置和快捷键将被默认值替换。");
        [alert addButtonWithTitle:T(@"Cancel", @"取消")]; [alert addButtonWithTitle:T(@"Restore", @"恢复")];
        [alert beginSheetModalForWindow:settingsWindow completionHandler:^(NSModalResponse response) {
            if (response == NSAlertSecondButtonReturn) { ConfigHandler().setDefaultSettings(); rebuild(); }
        }];
    });
    return row(@[importButton, exportButton, reset]);
}
NSArray<NSView*>* toolbarSettings()
{
    auto controls = [NSMutableArray<NSView*> new];
    [controls addObject:heading(@"Capture toolbar", @"截图工具栏")];
    [controls addObject:text(T(@"Choose which tools appear in the toolbar and More menu. Keyboard shortcuts remain available.", @"选择工具栏和“更多工具”菜单中显示的工具，隐藏后仍可使用快捷键。"), YES)];
    auto all = [NSMutableArray<NSButton*> new];
    for (auto type : CaptureToolButton::getIterableButtonTypes()) {
        std::unique_ptr<CaptureTool> tool(ToolFactory().CreateTool(type));
        auto b = [NSButton checkboxWithTitle:S(tool->name()) target:nil action:nil];
        b.state = ConfigHandler().buttons().contains(type) ? NSControlStateValueOn : NSControlStateValueOff;
        b.toolTip = S(tool->description());
        on(b, ^(NSButton* sender) {
            auto selected = ConfigHandler().buttons(); selected.removeAll(type);
            if (sender.state == NSControlStateValueOn) selected.append(type);
            std::sort(selected.begin(), selected.end(), [](auto a, auto b) {
                return CaptureToolButton::getPriorityByButton(a) < CaptureToolButton::getPriorityByButton(b);
            });
            ConfigHandler().setButtons(selected);
        });
        [controls addObject:b]; [all addObject:b];
    }
    [controls addObject:push(T(@"Select all", @"全选"), ^(id) {
        ConfigHandler().setAllTheButtons(); for (NSButton* b in all) b.state = NSControlStateValueOn;
    })];
    return controls;
}
NSArray<NSView*>* paletteSettings()
{
    auto controls = [NSMutableArray<NSView*> new];
    [controls addObject:heading(@"Selection and annotation colors", @"选区与标注颜色")];
    auto border = color("uiColor", @"Custom selection border", @"自定义选区边框");
    auto contrast = color("contrastUiColor", @"Custom selection contrast", @"自定义选区对比色");
    auto follow = [NSButton checkboxWithTitle:T(@"Use the system accent color for selection", @"选区颜色跟随系统强调色") target:nil action:nil];
    follow.state = ConfigHandler().useSystemAccentColor() ? NSControlStateValueOn : NSControlStateValueOff;
    auto enableCustom = ^(BOOL enabled) {
        for (NSStackView* row in @[border, contrast]) for (NSView* child in row.arrangedSubviews)
            if ([child isKindOfClass:NSControl.class]) ((NSControl*)child).enabled = enabled;
    };
    enableCustom(!ConfigHandler().useSystemAccentColor());
    on(follow, ^(NSButton* sender) {
        bool enabled = sender.state == NSControlStateValueOn;
        ConfigHandler().setUseSystemAccentColor(enabled); enableCustom(!enabled);
    });
    [controls addObject:follow];
    [controls addObject:border]; [controls addObject:contrast];
    [controls addObject:color("drawColor", @"Default annotation color", @"默认标注颜色")];
    [controls addObject:integer("contrastOpacity", @"Outside selection dimming", @"选区外遮罩深度", 0, 255)];
    [controls addObject:heading(@"Color presets", @"预设颜色")];
    const auto colors = ConfigHandler().userColors();
    for (int i = 0; i < colors.size(); ++i) {
        auto well = [NSColorWell new]; const QColor initial = colors[i];
        well.color = [NSColor colorWithSRGBRed:initial.redF() green:initial.greenF() blue:initial.blueF() alpha:initial.alphaF()];
        on(well, ^(NSColorWell* sender) {
            auto palette = ConfigHandler().userColors();
            if (i >= palette.size()) return;
            auto c = [sender.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            palette[i] = QColor::fromRgbF(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent);
            ConfigHandler().setUserColors(palette);
        });
        auto remove = push(T(@"Remove", @"移除"), ^(id) {
            auto palette = ConfigHandler().userColors();
            if (palette.size() > 3 && i < palette.size()) { palette.removeAt(i); ConfigHandler().setUserColors(palette); rebuild(); }
        });
        remove.enabled = colors.size() > 3;
        [controls addObject:row(@[text([NSString stringWithFormat:T(@"Color %d", @"颜色 %d"), i + 1]), well, remove])];
    }
    auto add = push(T(@"Add color", @"添加颜色"), ^(id) {
        auto colors = ConfigHandler().userColors(); if (colors.size() < 17) { colors.append(Qt::red); ConfigHandler().setUserColors(colors); rebuild(); }
    }); add.enabled = colors.size() < 17; [controls addObject:add];
    [controls addObject:boolean("predefinedColorPaletteLarge", @"Use the large built-in color palette", @"使用较大的内置调色板")];
    return controls;
}
NSString* shortcutTitle(const QString& key)
{
    const auto meta = QMetaEnum::fromType<CaptureTool::Type>();
    bool found = false; const int type = meta.keyToValue(key.toUtf8().constData(), &found);
    if (found) { std::unique_ptr<CaptureTool> tool(ToolFactory().CreateTool((CaptureTool::Type)type)); if (tool) return S(tool->name()); }
    const QMap<QString, QPair<NSString*, NSString*>> names = {
        {"TYPE_CANCEL", {@"Clear capture region", @"清除截图选区"}},
        {"TAKE_SCREENSHOT", {@"Capture screen", @"全局截图"}},
        {"TYPE_TOGGLE_PANEL", {@"Tool settings", @"工具设置"}},
        {"TYPE_GRAB_COLOR", {@"Pick a screen color", @"拾取屏幕颜色"}},
        {"TYPE_SELECT_ALL", {@"Select entire screen", @"选择整个屏幕"}},
        {"TYPE_COMMIT_CURRENT_TOOL", {@"Commit text", @"完成文字编辑"}},
        {"TYPE_DELETE_CURRENT_TOOL", {@"Delete annotation", @"删除标注"}},
        {"TYPE_CLOSE_ACTIVE_PIN_WINDOW", {@"Close pinned capture", @"关闭置顶截图"}},
        {"TYPE_RESIZE_LEFT", {@"Resize left", @"向左调整选区"}}, {"TYPE_RESIZE_RIGHT", {@"Resize right", @"向右调整选区"}},
        {"TYPE_RESIZE_UP", {@"Resize up", @"向上调整选区"}}, {"TYPE_RESIZE_DOWN", {@"Resize down", @"向下调整选区"}},
        {"TYPE_SYM_RESIZE_LEFT", {@"Decrease width symmetrically", @"对称缩小宽度"}},
        {"TYPE_SYM_RESIZE_RIGHT", {@"Increase width symmetrically", @"对称增大宽度"}},
        {"TYPE_SYM_RESIZE_UP", {@"Increase height symmetrically", @"对称增大高度"}},
        {"TYPE_SYM_RESIZE_DOWN", {@"Decrease height symmetrically", @"对称缩小高度"}},
        {"TYPE_MOVE_LEFT", {@"Move selection left", @"向左移动选区"}}, {"TYPE_MOVE_RIGHT", {@"Move selection right", @"向右移动选区"}},
        {"TYPE_MOVE_UP", {@"Move selection up", @"向上移动选区"}}, {"TYPE_MOVE_DOWN", {@"Move selection down", @"向下移动选区"}}
    };
    auto it = names.find(key); return it == names.end() ? S(key) : T(it->first, it->second);
}
NSArray<NSView*>* shortcutSettings()
{
    auto controls = [NSMutableArray<NSView*> new];
    [controls addObject:heading(@"Keyboard shortcuts", @"键盘快捷键")];
    [controls addObject:text(T(@"Click a shortcut and press a new combination. Escape cancels recording. Restart after changing global shortcuts.", @"点击快捷键后按下新的组合键，按 Esc 取消录制。修改全局快捷键后请重启应用。"), YES)];
    auto names = ConfigHandler::recognizedShortcutNames().values(); std::sort(names.begin(), names.end());
    names.removeAll("SCREENSHOT_HISTORY"); names.removeAll("TAKE_SCREENSHOT"); names.prepend("TAKE_SCREENSHOT");
    for (const QString& name : names) {
        auto title = text(shortcutTitle(name));
        auto recorder = [FSShortcutRecorder new]; recorder->binding = ConfigHandler().shortcut(name);
        recorder->save = [name](const QString& value) { return ConfigHandler().setShortcut(name, value); };
        recorder.bezelStyle = NSBezelStyleRounded;
        recorder.target = recorder; recorder.action = @selector(record:); [recorder refresh];
        [recorder.widthAnchor constraintEqualToConstant:140].active = YES;
        [recorder setAccessibilityLabel:shortcutTitle(name)];
        auto clear = push(T(@"Clear", @"清除"), ^(id) {
            if (recorder->save(QString())) { recorder->binding.clear(); [recorder refresh]; }
        });
        [controls addObject:row(@[title, recorder, clear], YES)];
    }
    return controls;
}
}

bool MacUI::setLaunchAtLogin(bool enabled)
{
    NSError* error = nil;
    BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError:&error] :
                        [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!ok && error) message(T(@"Login item could not be updated", @"无法更改登录项"), error.localizedDescription);
    return ok;
}

void MacUI::showPreferences()
{
    installMenu();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (settingsWindow) { [settingsWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; return; }
    auto tabs = [NSTabViewController new]; tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    auto languages = [NSMutableArray<NSString*> arrayWithObjects:T(@"Follow System", @"跟随系统"), @"简体中文", @"English", nil];
    QStringList codes = {"auto", "zh_CN", "en"};
    for (const auto& path : PathInfo::translationsPaths()) for (const auto& file : QDir(path).entryList({"Internationalization_*.qm"}, QDir::Files)) {
        auto code = file.mid(21); code.chop(3); if (codes.contains(code)) continue;
        codes << code; [languages addObject:S(QLocale(code).nativeLanguageName() + " (" + code + ")")];
    }
    auto language = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; [language addItemsWithTitles:languages];
    [language selectItemAtIndex:qMax(0, codes.indexOf(ConfigHandler().uiLanguage()))];
    on(language, ^(NSPopUpButton* sender) {
        ConfigHandler().setUiLanguage(codes[(int)sender.indexOfSelectedItem]);
        message(T(@"Language updated", @"语言已更新"), T(@"Restart Flameshoter to update all menus and windows.", @"重新启动 Flameshoter 后，所有菜单和窗口将使用新语言。"));
    });
    auto general = [NSMutableArray<NSView*> arrayWithArray:@[
        heading(@"Language", @"语言"), language,
        heading(@"Startup and behavior", @"启动与行为"),
        boolean("startupLaunch", @"Launch at login", @"登录时启动"),
        boolean("disabledTrayIcon", @"Show menu bar icon", @"显示菜单栏图标", YES),
        boolean("showStartupLaunchMessage", @"Show welcome notification", @"显示启动通知"),
        boolean("autoCloseIdleDaemon", @"Unload the background process when idle", @"闲置时退出后台进程"),
        boolean("allowMultipleGuiInstances", @"Allow simultaneous capture sessions", @"允许同时打开多个截图会话"),
        boolean("showDesktopNotification", @"Show desktop notifications", @"显示桌面通知"),
        boolean("showAbortNotification", @"Notify when capture is cancelled", @"取消截图时通知"),
        boolean("showHelp", @"Show capture instructions", @"显示截图操作提示"),
        boolean("showQuitPrompt", @"Confirm before discarding a capture", @"丢弃截图前询问"),
        heading(@"Configuration file", @"配置文件"), fileControls(),
        text(T(@"Flameshot .ini configuration files can be imported. Appearance follows macOS accessibility and display preferences.", @"支持导入 Flameshot 的 .ini 配置文件。外观遵循 macOS 辅助功能与显示设置。"), YES)
    ]];
#if !defined(DISABLE_UPDATE_CHECKER)
    [general addObject:boolean("checkForUpdates", @"Check for updates automatically", @"自动检查更新")];
#endif
    [tabs addTabViewItem:tab(T(@"General", @"通用"), @"gearshape", general)];
    [tabs addTabViewItem:tab(T(@"Capture", @"截图"), @"viewfinder", @[
        heading(@"Selection", @"选区"),
        boolean("saveLastRegion", @"Remember the last capture region", @"记住上次截图区域"),
        boolean("copyOnDoubleClick", @"Double-click to copy", @"双击复制截图"),
        boolean("showMagnifier", @"Show magnifier", @"显示放大镜"),
        boolean("squareMagnifier", @"Use a square magnifier", @"使用方形放大镜"),
        boolean("showSidePanelButton", @"Show Tool Settings button", @"显示工具设置按钮"),
        boolean("useNativeFullscreen", @"Use native macOS full screen", @"使用 macOS 原生全屏模式"),
        popup("showSelectionGeometry", @"Selection geometry", @"选区尺寸显示", @[
            T(@"Off", @"关闭"), T(@"Top left", @"左上角"), T(@"Top right", @"右上角"),
            T(@"Bottom left", @"左下角"), T(@"Bottom right", @"右下角"), T(@"Center", @"居中")]),
        integer("showSelectionGeometryHideTime", @"Geometry display time (ms)", @"尺寸提示显示时间（毫秒）", 0, 60000),
        integer("undoLimit", @"Undo history limit", @"撤销历史上限", 0, 999),
        heading(@"Pinned captures", @"置顶截图"),
        boolean("antialiasingPinZoom", @"Smooth pinned capture zoom", @"平滑缩放置顶截图"),
        push(T(@"Screen Recording permissions…", @"屏幕录制权限…"), ^(id) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        }),
        push(T(@"Restart Flameshoter", @"重新启动 Flameshoter"), ^(id) { restartApp(); }),
        push(T(@"Repair Screen Recording authorization…", @"修复屏幕录制授权…"), ^(id) { repairScreenCaptureAccess(); })])];
    [tabs addTabViewItem:tab(T(@"Toolbar", @"工具栏"), @"slider.horizontal.3", toolbarSettings())];
    [tabs addTabViewItem:tab(T(@"Colors", @"颜色"), @"paintpalette", paletteSettings())];
    auto path = [NSTextField textFieldWithString:S(ConfigHandler().savePath())];
    [path setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [path setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    on(path, ^(NSTextField* sender) {
        if (QDir(Q(sender.stringValue)).exists()) ConfigHandler().setSavePath(Q(sender.stringValue));
        else { NSBeep(); sender.stringValue = S(ConfigHandler().savePath()); }
    });
    auto choose = push(T(@"Choose…", @"选择…"), ^(id) {
        auto panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.canCreateDirectories = YES;
        [panel beginSheetModalForWindow:settingsWindow completionHandler:^(NSModalResponse response) {
            if (response == NSModalResponseOK) { ConfigHandler().setSavePath(Q(panel.URL.path)); path.stringValue = panel.URL.path; }
        }];
    });
    auto filename = [NSTextField textFieldWithString:S(ConfigHandler().filenamePattern())];
    [filename setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    auto preview = text(S(FileNameHandler().parsedPattern()), YES);
    on(filename, ^(NSTextField* sender) {
        if (ConfigHandler::validSetting("General", "filenamePattern", Q(sender.stringValue))) {
            ConfigHandler().setFilenamePattern(Q(sender.stringValue)); preview.stringValue = S(FileNameHandler().parsedPattern());
        } else NSBeep();
    });
    [tabs addTabViewItem:tab(T(@"Save", @"保存"), @"square.and.arrow.down", @[
        heading(@"Save folder", @"保存位置"), row(@[path, choose], YES),
        boolean("savePathFixed", @"Save directly to the selected folder", @"直接保存到所选文件夹"),
        heading(@"Filename pattern", @"文件名格式"), filename, preview,
        text(T(@"%Y year · %m month · %d day · %H hour · %M minute · %S second\nExample: Screenshot_%Y-%m-%d_%H-%M-%S", @"%Y 年 · %m 月 · %d 日 · %H 时 · %M 分 · %S 秒\n示例：截图_%Y-%m-%d_%H-%M-%S"), YES),
        popup("saveAsFileExtension", @"Image format", @"图片格式", @[@"PNG", @"JPEG", @"BMP"], {"png", "jpg", "bmp"}),
        integer("jpegQuality", @"JPEG quality", @"JPEG 质量", 0, 100),
        boolean("saveAfterCopy", @"Also save after copying", @"复制后同时保存"),
        boolean("copyPathAfterSave", @"Copy the path after saving", @"保存后复制路径"),
        boolean("useJpgForClipboard", @"Use JPEG on the clipboard", @"以 JPEG 格式复制到剪贴板"),
        boolean("keepOpenAppLauncher", @"Keep the external app chooser open", @"保持外部应用选择窗口打开")])];
    auto fonts = [NSMutableArray<NSString*> arrayWithObject:T(@"System font", @"系统字体")];
    QStringList fontValues = {""};
    for (NSString* family in NSFontManager.sharedFontManager.availableFontFamilies) { [fonts addObject:family]; fontValues << Q(family); }
    [tabs addTabViewItem:tab(T(@"Annotation", @"标注"), @"pencil.tip", @[
        heading(@"Default tool parameters", @"工具默认参数"),
        integer("drawThickness", @"Pencil, line, arrow and ellipse width", @"画笔、直线、箭头与椭圆线宽", 1, 500),
        integer("drawRectangleSize", @"Rectangle width", @"矩形线宽", 1, 500),
        integer("drawMarkerSize", @"Marker width", @"荧光笔宽度", 1, 500),
        integer("drawFontSize", @"Text point size", @"文字字号", 1, 492, 8),
        integer("drawCircleCounterSize", @"Number annotation size", @"序号标注尺寸", 1, 500),
        integer("drawPixelateSize", @"Pixelation size", @"马赛克尺寸", 1, 500),
        popup("fontFamily", @"Default font", @"默认字体", fonts, fontValues),
        boolean("drawCircleCounterOutline", @"Outline numbered annotations", @"为序号标注绘制轮廓"),
        boolean("reverseArrow", @"Reverse arrow direction", @"反转箭头方向"),
        popup("arrowStyle", @"Arrow style", @"箭头样式", @[T(@"Straight", @"直线箭头"), T(@"Curved", @"弯曲箭头")]),
        boolean("insecurePixelate", @"Use traditional pixelation", @"使用传统像素化马赛克"),
        text(T(@"Traditional pixelation may retain information. The default method replaces the interior using surrounding colors.", @"传统像素化可能保留原始信息。默认方法会使用周围颜色替换区域内部内容。"), YES)])];
    [tabs addTabViewItem:tab(T(@"Shortcuts", @"快捷键"), @"keyboard", shortcutSettings())];
    settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,660,620)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    settingsWindow.releasedWhenClosed = NO;
    settingsWindow.title = T(@"Flameshoter Settings", @"Flameshoter 设置");
    settingsWindow.contentViewController = tabs;
    settingsWindow.contentMinSize = NSMakeSize(580, 480);
    [settingsWindow setContentSize:NSMakeSize(660, 620)];
    [settingsWindow center]; [settingsWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
