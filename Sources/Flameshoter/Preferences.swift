// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor final class ShortcutRecorder: NSButton {
  let binding: String
  var save: ((Shortcut?) -> Bool)?
  private var recording = false
  init(binding: String) {
    self.binding = binding
    super.init(frame: .zero)
    bezelStyle = .rounded
    target = self
    action = #selector(record)
    refresh()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override var acceptsFirstResponder: Bool { true }
  @objc private func record() {
    recording = true
    title = localized("Press shortcut…", "按下快捷键…")
    window?.makeFirstResponder(self)
  }
  func refresh() {
    title =
      Environment.shared.preferences.shortcut(binding)?.display ?? localized("Not assigned", "未设置")
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if recording {
      keyDown(with: event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
  override func keyDown(with event: NSEvent) {
    guard recording else {
      super.keyDown(with: event)
      return
    }
    recording = false
    if event.keyCode != 53 {
      _ = save?(Shortcut(event.keyCode, event.modifierFlags.intersection(Shortcut.relevant)))
    }
    refresh()
  }
}

@MainActor final class PreferencesTabs: NSTabViewController {
  var onSelection: (() -> Void)?
  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    onSelection?()
  }
}

@MainActor final class PreferencesController: NSWindowController {
  private let tabs = PreferencesTabs()
  private var rebuilding = false
  private var settings: SettingsStore { Environment.shared.settings }
  private var p: Preferences { settings.preferences }
  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = localized("Flameshoter Settings", "Flameshoter 设置")
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 720, height: 360)
    window.center()
    window.setFrameAutosaveName("FlameshoterNativePreferences")
    super.init(window: window)
    tabs.tabStyle = .toolbar
    window.contentViewController = tabs
    rebuild()
    tabs.onSelection = { [weak self] in self?.fitSelectedPage() }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  private func fitSelectedPage() {
    guard !rebuilding, let window,
      tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex),
      let scroll = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view
        as? NSScrollView,
      let document = scroll.documentView
    else { return }
    tabs.view.layoutSubtreeIfNeeded()
    let chrome = window.frame.height - scroll.frame.height
    let maximum = min(760, (window.screen ?? NSScreen.main)!.visibleFrame.height - 40)
    let height = min(maximum, max(window.minSize.height, document.fittingSize.height + chrome))
    var frame = window.frame
    frame.origin.y += frame.height - height
    frame.size.height = height
    window.setFrame(frame, display: true, animate: window.isVisible)
  }
  private func heading(_ en: String, _ zh: String) -> NSView {
    let view = label(localized(en, zh), size: 15)
    view.font = .systemFont(ofSize: 15, weight: .semibold)
    return view
  }
  private func row(_ en: String, _ zh: String, _ control: NSView) -> NSStackView {
    let name = label(localized(en, zh))
    name.widthAnchor.constraint(equalToConstant: 240).isActive = true
    control.setContentHuggingPriority(.required, for: .horizontal)
    return stack([name, control, NSView()], vertical: false, spacing: 12)
  }
  private func boolean(_ key: String, _ en: String, _ zh: String, inverse: Bool = false) -> NSView {
    let check = ActionCheck(localized(en, zh), on: inverse ? !p.bool(key) : p.bool(key)) {
      [weak self] value in self?.settings.set(key, inverse ? !value : value)
    }
    if key == "startupLaunch" {
      check.change = { [weak self, weak check] value in
        do {
          if value {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
          self?.settings.set(key, value)
        } catch {
          check?.state = value ? .off : .on
          warning(
            localized("Login setting could not be changed", "无法更改登录启动设置"), errorMessage(error),
            window: self?.window)
        }
      }
    }
    if ["showDesktopNotification", "showStartupLaunchMessage", "showAbortNotification"].contains(
      key)
    {
      check.change = { [weak self, weak check] value in
        if !value {
          self?.settings.set(key, false)
          return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
          allowed, error in
          Task { @MainActor in
            self?.settings.set(key, allowed)
            check?.state = allowed ? .on : .off
            if let error {
              warning(localized("Notifications unavailable", "通知不可用"), errorMessage(error))
            }
          }
        }
      }
    }
    return check
  }
  private func columns(_ controls: [NSView], count: Int) -> NSStackView {
    let columns = (0..<count).map { column in
      stack(controls.enumerated().filter { $0.offset % count == column }.map(\.element), spacing: 8)
    }
    let result = stack(columns, vertical: false, spacing: 16)
    result.alignment = .top
    result.distribution = .fillEqually
    return result
  }
  private func integer(_ key: String, _ en: String, _ zh: String, _ range: ClosedRange<Int>)
    -> NSView
  {
    let field = ActionField(String(p.integer(key))) { [weak self] value in
      guard let n = Int(value), range.contains(n) else {
        warning(
          localized("Value out of range", "数值超出范围"), "\(range.lowerBound)…\(range.upperBound)",
          window: self?.window)
        return
      }
      self?.settings.set(key, n)
    }
    let formatter = NumberFormatter()
    formatter.allowsFloats = false
    formatter.minimum = NSNumber(value: range.lowerBound)
    formatter.maximum = NSNumber(value: range.upperBound)
    field.formatter = formatter
    field.widthAnchor.constraint(equalToConstant: 100).isActive = true
    return row(en, zh, field)
  }
  private func popup(
    _ key: String, _ en: String, _ zh: String, _ items: [String], values: [String]? = nil
  ) -> NSView {
    let values = values ?? items.indices.map(String.init)
    let control = ActionPopup(items: items, selected: values.firstIndex(of: p.string(key)) ?? 0) {
      [weak self] index in self?.settings.set(key, values[index])
    }
    control.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
    return row(en, zh, control)
  }
  private func color(_ key: String, _ en: String, _ zh: String) -> NSView {
    row(
      en, zh,
      ActionColor(color: p.color(key).color) { [weak self] value in
        self?.settings.set(key, RGBA(value).hex)
      })
  }
  private func page(_ en: String, _ zh: String, _ symbol: String, _ controls: [NSView]) {
    let column = stack(controls, spacing: 10)
    let document = FlippedView()
    let scroll = NSScrollView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(column)
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = document
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
      column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
      column.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
      column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    for control in controls where !(control is NSButton) {
      control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    let controller = NSViewController()
    controller.view = scroll
    let item = NSTabViewItem(viewController: controller)
    item.label = localized(en, zh)
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
    tabs.addTabViewItem(item)
  }
  func rebuild() {
    rebuilding = true
    defer {
      rebuilding = false
      fitSelectedPage()
    }
    let selected = tabs.selectedTabViewItemIndex
    for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
    var general: [NSView] = [heading("Language and application", "语言与应用")]
    let languages = ActionPopup(
      items: [localized("System", "跟随系统"), "简体中文", "English"],
      selected: ["auto", "zh_CN", "en"].firstIndex(of: p.string("uiLanguage")) ?? 0
    ) { [weak self] index in
      self?.settings.set("uiLanguage", ["auto", "zh_CN", "en"][index])
      self?.rebuild()
    }
    general += [
      row("Language", "界面语言", languages),
      label(
        localized("Restart to apply the language to all system dialogs.", "重启后，语言将应用到所有系统对话框。"),
        secondary: true),
      ActionButton(localized("Restart Flameshoter", "重新启动 Flameshoter")) { Permissions.restart() },
    ]
    general += [
      heading("Application behavior", "应用行为"),
      columns(
        [
          boolean("startupLaunch", "Launch at login", "登录时启动"),
          boolean("disabledTrayIcon", "Show menu-bar icon", "显示菜单栏图标", inverse: true),
          boolean(
            "autoCloseIdleDaemon", "Quit when idle with the menu-bar icon hidden", "隐藏菜单栏图标时闲置自动退出"),
          boolean(
            "allowMultipleGuiInstances", "Allow simultaneous capture sessions", "允许同时打开多个截图会话"),
          boolean("showHelp", "Show capture instructions", "显示截图操作提示"),
          boolean("showQuitPrompt", "Confirm before discarding annotations", "丢弃标注前询问"),
        ], count: 2),
      heading("Notifications", "通知"),
      columns(
        [
          boolean("showDesktopNotification", "Show save notifications", "显示保存通知"),
          boolean("showStartupLaunchMessage", "Show a welcome notification", "显示启动通知"),
          boolean("showAbortNotification", "Notify when a capture is cancelled", "取消截图时通知"),
        ], count: 2),
      heading("Configuration", "配置文件"), fileControls(),
      label(
        localized(
          "Import Flameshot INI settings or export a backup.", "可导入 Flameshot 的 INI 配置，也可导出备份。"),
        secondary: true),
    ]
    page("General", "通用", "gearshape", general)
    page(
      "Capture", "截图", "viewfinder",
      [
        heading("Selection", "截图选区"),
        boolean("saveLastRegion", "Remember the last capture region", "记住上次截图区域"),
        boolean("copyOnDoubleClick", "Double-click to copy", "双击复制截图"),
        boolean("showMagnifier", "Show pixel magnifier", "显示像素放大镜"),
        boolean("squareMagnifier", "Use a square magnifier", "使用方形放大镜"),
        boolean("showSidePanelButton", "Show Tool Settings button", "显示工具设置按钮"),
        boolean("useNativeFullscreen", "Use native macOS fullscreen", "使用 macOS 原生全屏"),
        popup(
          "showSelectionGeometry", "Selection dimensions", "选区尺寸显示",
          [
            localized("Off", "关闭"), localized("Top left", "左上角"), localized("Top right", "右上角"),
            localized("Bottom left", "左下角"),
            localized("Bottom right", "右下角"), localized("Center", "居中"),
          ]),
        integer(
          "showSelectionGeometryHideTime", "Dimension display time (ms)", "尺寸提示时间（毫秒）", 0...60000),
        integer("undoLimit", "Undo history limit (0 = unlimited)", "撤销历史上限（0 为不限）", 0...999),
        heading("Pinned captures", "置顶截图"),
        boolean("antialiasingPinZoom", "Smooth pinned image zoom", "平滑缩放置顶截图"),
        ActionButton(localized("Screen Recording permissions…", "屏幕录制权限…")) {
          Permissions.openSettings()
        },
        ActionButton(localized("Repair Screen Recording authorization…", "修复屏幕录制授权…")) {
          Permissions.repair()
        },
      ])
    var tools: [NSView] = [
      heading("Capture toolbar", "截图工具栏"),
      label(
        localized(
          "Enabled tools appear directly around the capture region, in Flameshot order. Shortcuts remain available.",
          "已启用的工具按 Flameshot 原版顺序直接显示在选区周围，隐藏后仍可使用快捷键。"), secondary: true),
    ]
    var toolChecks: [NSView] = []
    for tool in Tool.toolbarOrder {
      toolChecks.append(
        ActionCheck(toolTitle(tool), on: p.tools.contains(tool)) { [weak self] on in
          self?.settings.update { prefs in
            prefs.tools.removeAll { $0 == tool }
            if on { prefs.tools.append(tool) }
          }
        })
    }
    tools.append(columns(toolChecks, count: 3))
    tools.append(
      ActionButton(localized("Select all", "全选")) { [weak self] in
        self?.settings.update { $0.tools = Tool.toolbarOrder }
        self?.rebuild()
      })
    page("Toolbar", "工具栏", "slider.horizontal.3", tools)
    var colors: [NSView] = [
      heading("System appearance and colors", "系统外观与颜色"),
      boolean("useSystemAccentColor", "Use the system glass appearance", "使用系统玻璃外观"),
      color("uiColor", "Custom glass tint", "自定义玻璃着色"),
      color("drawColor", "Default annotation color", "默认标注颜色"),
      integer("contrastOpacity", "Outside frost strength", "选区外毛玻璃强度", 0...255),
      heading("Color presets", "预设颜色"),
      boolean("predefinedColorPaletteLarge", "Show expanded Apple color presets", "显示扩展的苹果预设色"),
    ]
    var presetRows: [NSView] = []
    for (index, value) in p.colors.enumerated() {
      let well = ActionColor(color: value.color) { [weak self] color in
        self?.settings.update {
          if $0.colors.indices.contains(index) { $0.colors[index] = RGBA(color) }
        }
      }
      let remove = ActionButton(localized("Remove", "移除")) { [weak self] in
        self?.settings.update { if $0.colors.count > 3 { $0.colors.remove(at: index) } }
        self?.rebuild()
      }
      remove.isEnabled = p.colors.count > 3
      presetRows.append(
        stack(
          [label(localized("Color ", "颜色 ") + String(index + 1)), well, remove, NSView()],
          vertical: false))
    }
    colors.append(columns(presetRows, count: 2))
    let add = ActionButton(localized("Add color", "添加颜色")) { [weak self] in
      self?.settings.update { $0.colors.append(.red) }
      self?.rebuild()
    }
    add.isEnabled = p.colors.count < 17
    colors.append(add)
    page("Colors", "颜色", "paintpalette", colors)
    let path = ActionField(p.saveDirectory.path) { [weak self] value in
      self?.settings.set("savePath", value)
    }
    let choose = ActionButton(localized("Choose…", "选择…")) { [weak self, weak path] in
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      if panel.runModal() == .OK, let url = panel.url {
        self?.settings.set("savePath", url.path)
        path?.stringValue = url.path
      }
    }
    let pattern = ActionField(p.string("filenamePattern")) { [weak self] value in
      self?.settings.set("filenamePattern", value)
      self?.rebuild()
    }
    let formats = Files.supportedFormats
    page(
      "Saving", "保存", "square.and.arrow.down",
      [
        heading("Save location", "保存位置"), stack([path, choose], vertical: false),
        boolean("savePathFixed", "Save directly to this folder", "直接保存到此文件夹"),
        heading("Filename pattern", "文件名格式"), pattern,
        label(FilenamePattern.render(p.string("filenamePattern")), secondary: true),
        label(
          localized(
            "%Y year · %m month · %d day · %H hour · %M minute · %S second\nExample: Capture_%F_%H-%M-%S",
            "%Y 年 · %m 月 · %d 日 · %H 时 · %M 分 · %S 秒\n示例：截图_%F_%H-%M-%S"), secondary: true),
        popup(
          "saveAsFileExtension", "Image format", "图片格式", formats.map(\.1), values: formats.map(\.0)),
        integer("jpegQuality", "JPEG quality", "JPEG 质量", 0...100),
        boolean("saveAfterCopy", "Also save after copying", "复制后同时保存"),
        boolean("copyPathAfterSave", "Copy the path after saving", "保存后复制路径"),
        boolean("useJpgForClipboard", "Use JPEG on the clipboard", "以 JPEG 格式复制到剪贴板"),
        boolean("keepOpenAppLauncher", "Keep the external app chooser open", "保持外部应用选择窗口打开"),
      ])
    let fonts =
      [localized("System font", "系统字体")] + NSFontManager.shared.availableFontFamilies.sorted()
    page(
      "Annotation", "标注", "pencil.tip",
      [
        heading("Default tool parameters", "工具默认参数"),
        integer("drawThickness", "Pencil, line, arrow and ellipse width", "画笔、直线、箭头与椭圆线宽", 1...500),
        integer("drawRectangleSize", "Rectangle width", "矩形线宽", 1...500),
        integer("drawMarkerSize", "Marker width", "荧光笔宽度", 1...500),
        integer("drawFontSize", "Text size (points)", "文字字号", 1...500),
        integer("drawCircleCounterSize", "Number annotation diameter", "序号标注直径", 1...500),
        integer("drawPixelateSize", "Redaction / pixelation block size", "遮挡 / 马赛克块尺寸", 1...500),
        popup("fontFamily", "Default font", "默认字体", fonts, values: [""] + Array(fonts.dropFirst())),
        boolean("drawCircleCounterOutline", "Outline numbered annotations", "为序号标注绘制轮廓"),
        boolean("reverseArrow", "Reverse arrow direction", "反转箭头方向"),
        popup(
          "arrowStyle", "Arrow style", "箭头样式",
          [localized("Straight", "直线箭头"), localized("Curved", "弯曲箭头")]),
        boolean("insecurePixelate", "Use traditional pixelation", "使用传统像素化马赛克"),
        label(
          localized(
            "Traditional pixelation may retain information. The default redaction replaces the interior using surrounding colors.",
            "传统像素化可能保留原始信息。默认遮挡使用周围颜色替换内部内容。"), secondary: true),
      ])
    var shortcuts: [NSView] = [
      heading("Keyboard shortcuts", "键盘快捷键"),
      label(
        localized(
          "Click to record. Escape cancels. Global shortcuts update immediately.",
          "点击后录制新的组合键，Esc 取消。全局快捷键立即生效。"), secondary: true),
    ]
    let keys =
      ["TAKE_SCREENSHOT"] + Shortcut.defaults.keys.filter { $0 != "TAKE_SCREENSHOT" }.sorted()
    for key in keys {
      let recorder = ShortcutRecorder(binding: key)
      recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
      recorder.save = { [weak self] proposed in
        guard let self else { return false }
        if let proposed,
          self.p.shortcuts.contains(where: {
            $0.key != key && !self.p.unassignedShortcuts.contains($0.key) && $0.value == proposed
          })
        {
          warning(
            localized("Shortcut unavailable", "快捷键不可用"),
            localized("Another action uses this combination.", "其他操作已使用此组合键。"), window: self.window)
          return false
        }
        if key == "TAKE_SCREENSHOT", let app = NSApp.delegate as? AppController,
          !app.assignGlobalShortcut(proposed)
        {
          return false
        }
        self.settings.update {
          if let proposed {
            $0.shortcuts[key] = proposed
            $0.unassignedShortcuts.remove(key)
          } else {
            $0.unassignedShortcuts.insert(key)
          }
        }
        return true
      }
      let clear = ActionButton(localized("Clear", "清除")) {
        _ = recorder.save?(nil)
        recorder.refresh()
      }
      let name = label(shortcutTitle(key))
      name.widthAnchor.constraint(equalToConstant: 220).isActive = true
      shortcuts.append(stack([name, recorder, clear, NSView()], vertical: false, spacing: 12))
    }
    page("Shortcuts", "快捷键", "keyboard", shortcuts)
    tabs.selectedTabViewItemIndex = min(max(0, selected), tabs.tabViewItems.count - 1)
  }
  private func shortcutTitle(_ key: String) -> String {
    if let tool = Tool.allCases.first(where: { $0.legacyName == key }) { return toolTitle(tool) }
    let names = [
      "TAKE_SCREENSHOT": ("Global capture", "全局截图"), "TYPE_TOGGLE_PANEL": ("Tool settings", "工具设置"),
      "TYPE_SELECT_ALL": ("Select entire screen", "选择整个屏幕"),
      "TYPE_DELETE_CURRENT_TOOL": ("Delete annotation", "删除标注"),
      "TYPE_COMMIT_CURRENT_TOOL": ("Commit text", "完成文字编辑"),
      "TYPE_GRAB_COLOR": ("Pick a screen color", "拾取屏幕颜色"),
      "TYPE_CLOSE_ACTIVE_PIN_WINDOW": ("Close pinned capture", "关闭置顶截图"),
      "TYPE_MOVE_LEFT": ("Move left", "向左移动选区"), "TYPE_MOVE_RIGHT": ("Move right", "向右移动选区"),
      "TYPE_MOVE_UP": ("Move up", "向上移动选区"), "TYPE_MOVE_DOWN": ("Move down", "向下移动选区"),
      "TYPE_RESIZE_LEFT": ("Decrease width", "缩小选区宽度"),
      "TYPE_RESIZE_RIGHT": ("Increase width", "增加选区宽度"),
      "TYPE_RESIZE_UP": ("Decrease height", "缩小选区高度"),
      "TYPE_RESIZE_DOWN": ("Increase height", "增加选区高度"),
      "TYPE_SYM_RESIZE_LEFT": ("Decrease width symmetrically", "对称缩小宽度"),
      "TYPE_SYM_RESIZE_RIGHT": ("Increase width symmetrically", "对称增加宽度"),
      "TYPE_SYM_RESIZE_UP": ("Decrease height symmetrically", "对称缩小高度"),
      "TYPE_SYM_RESIZE_DOWN": ("Increase height symmetrically", "对称增加高度"),
    ]
    let pair = names[key] ?? (key, key)
    return localized(pair.0, pair.1)
  }
  private func fileControls() -> NSView {
    stack(
      [
        ActionButton(localized("Import…", "导入…")) { [weak self] in
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          if panel.runModal() == .OK, let url = panel.url {
            do {
              try self?.settings.importFile(url)
              self?.rebuild()
            } catch {
              warning(localized("Import failed", "导入失败"), errorMessage(error), window: self?.window)
            }
          }
        },
        ActionButton(localized("Export…", "导出…")) { [weak self] in
          let panel = NSSavePanel()
          panel.nameFieldStringValue = "flameshoter.json"
          panel.allowedContentTypes = [.json, UTType(filenameExtension: "ini") ?? .plainText]
          if panel.runModal() == .OK, let url = panel.url {
            do { try self?.settings.exportFile(url) } catch {
              warning(localized("Export failed", "导出失败"), errorMessage(error), window: self?.window)
            }
          }
        },
        ActionButton(localized("Restore defaults…", "恢复默认设置…")) { [weak self] in
          let alert = NSAlert()
          alert.messageText = localized("Restore all defaults?", "恢复所有默认设置？")
          alert.informativeText = localized(
            "Your custom settings and shortcuts will be replaced.", "自定义设置和快捷键将被默认值替换。")
          alert.addButton(withTitle: localized("Cancel", "取消"))
          alert.addButton(withTitle: localized("Restore", "恢复"))
          if alert.runModal() == .alertSecondButtonReturn {
            self?.settings.reset()
            self?.rebuild()
          }
        },
        NSView(),
      ], vertical: false)
  }
}
