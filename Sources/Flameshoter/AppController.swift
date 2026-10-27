// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import UserNotifications

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var initialCommand: NativeCommand?
  private var item: NSStatusItem?
  private var launcher: NSWindowController?
  private var preferences: PreferencesController?
  private var sessions: [CaptureSession] = []
  private var pins: [PinWindowController] = []
  private var observers: [NSObjectProtocol] = []
  private var commandObserver: NSObjectProtocol?
  private let hotkey = GlobalHotkey()
  private var capturePending = false
  private var preparingRestart = false
  private var delay = 0
  private var standaloneCapture: Bool
  init(command: NativeCommand?) {
    initialCommand = command
    standaloneCapture =
      command.map { ["gui", "full", "screen"].contains($0.mode) && !$0.pin } ?? false
    super.init()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenus()
    configureStatusItem()
    configureHotkey()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didUpdateNotification, object: NSApp, queue: .main
      ) { _ in MainActor.assumeIsolated { DockPolicy.update(NSApp) } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: nil, queue: .main
      ) { [weak self] event in
        MainActor.assumeIsolated {
          let closingPreferences = (event.object as? NSWindow) === self?.preferences?.window
          DispatchQueue.main.async { [weak self] in
            if closingPreferences { self?.sessions.last?.show() }
            self?.quitIfIdle()
          }
        }
      })
    commandObserver = DistributedNotificationCenter.default().addObserver(
      forName: CommandBridge.requestName, object: CommandBridge.identifier, queue: .main
    ) { [weak self] notification in
      guard let json = notification.userInfo?["command"] as? String,
        let command = try? JSONDecoder().decode(NativeCommand.self, from: Data(json.utf8))
      else { return }
      Task { @MainActor in self?.handle(command) }
    }
    Environment.shared.settings.onChange = { [weak self] in
      self?.configureStatusItem()
      self?.configureHotkey()
      self?.installMenus()
      for session in self?.sessions ?? [] {
        for surface in session.surfaces { surface.canvas.refresh() }
      }
    }
    if let language = ["en": "en", "zh_CN": "zh-Hans", "zh-Hans": "zh-Hans"][
      Environment.shared.preferences.string("uiLanguage")]
    {
      UserDefaults.standard.set([language], forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
    if let command = initialCommand { handle(command) } else { showLauncher(nil) }
    if Environment.shared.preferences.bool("showStartupLaunchMessage") {
      notify(
        title: localized("Flameshoter is ready", "Flameshoter 已就绪"),
        body: localized("Capture from the menu bar or your global shortcut.", "可通过菜单栏或全局快捷键开始截图。"))
    }
    if let error = Environment.shared.settings.loadError {
      warning(localized("Settings could not be loaded", "设置读取失败"), errorMessage(error))
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if flag {
      NSApp.activate()
      return false
    }
    if let session = sessions.last {
      session.show()
      return false
    }
    if capturePending { return false }
    showLauncher(nil)
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if !preparingRestart
      && sessions.contains(where: { !$0.active.canvas.document.annotations.isEmpty }),
      Environment.shared.preferences.bool("showQuitPrompt")
    {
      for session in sessions { session.hide() }
      if !confirmDiscard() {
        for session in sessions { session.show() }
        return .terminateCancel
      }
    }
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let commandObserver {
      DistributedNotificationCenter.default().removeObserver(commandObserver)
    }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
  func prepareForRestart() -> Bool {
    if sessions.contains(where: { !$0.active.canvas.document.annotations.isEmpty }),
      Environment.shared.preferences.bool("showQuitPrompt")
    {
      for session in sessions { session.hide() }
      if !confirmDiscard() {
        for session in sessions { session.show() }
        return false
      }
    }
    preparingRestart = true
    for session in Array(sessions) { session.close(cancelled: true) }
    return true
  }
  func assignGlobalShortcut(_ shortcut: Shortcut?) -> Bool {
    guard ProcessInfo.processInfo.environment["FLAMESHOTER_TEST_CONFIG"] == nil else { return true }
    let old = Environment.shared.preferences.shortcut("TAKE_SCREENSHOT")
    if hotkey.register(shortcut) == noErr { return true }
    _ = hotkey.register(old)
    warning(
      localized("Global shortcut unavailable", "全局快捷键不可用"),
      localized(
        "Another application may be using this combination. Choose a different shortcut.",
        "此组合键可能已被其他应用占用，请选择其他组合键。"))
    return false
  }
  private func configureHotkey() {
    guard ProcessInfo.processInfo.environment["FLAMESHOTER_TEST_CONFIG"] == nil else { return }
    hotkey.invoke = { [weak self] in self?.capture(nil) }
    let status = hotkey.register(Environment.shared.preferences.shortcut("TAKE_SCREENSHOT"))
    if status != noErr {
      warning(
        localized("Global shortcut unavailable", "全局快捷键不可用"),
        localized(
          "Another application may be using this combination. Choose a different shortcut in Settings.",
          "此组合键可能已被其他应用占用，请在设置中选择其他快捷键。"))
    }
  }
  private func configureStatusItem() {
    if Environment.shared.preferences.bool("disabledTrayIcon") {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      return
    }
    if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
    item?.button?.image = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png")
      .flatMap { NSImage(contentsOf: $0) }
    item?.button?.image?.size = NSSize(width: 18, height: 18)
    item?.button?.image?.isTemplate = true
    item?.button?.setAccessibilityLabel("Flameshoter")
    item?.button?.toolTip = "Flameshoter"
    let menu = NSMenu()
    add(menu, localized("Capture region", "截取区域"), #selector(capture(_:)), symbol: "viewfinder")
    let displayItem = NSMenuItem(
      title: localized("Capture display", "截取指定屏幕"), action: nil, keyEquivalent: "")
    let displays = NSMenu()
    for (index, screen) in NSScreen.screens.enumerated() {
      let entry = NSMenuItem(
        title: "\(index+1). \(screen.localizedName)", action: #selector(captureDisplay(_:)),
        keyEquivalent: "")
      entry.tag = index
      entry.target = self
      displays.addItem(entry)
    }
    displayItem.submenu = displays
    menu.addItem(displayItem)
    menu.addItem(.separator())
    add(menu, localized("Open launcher…", "打开启动窗口…"), #selector(showLauncher(_:)))
    add(menu, localized("Settings…", "设置…"), #selector(showPreferences(_:)), symbol: "gearshape")
    add(menu, localized("About Flameshoter", "关于 Flameshoter"), #selector(showAbout(_:)))
    menu.addItem(.separator())
    add(menu, localized("Quit Flameshoter", "退出 Flameshoter"), #selector(quit(_:)), key: "q")
    item?.menu = menu
  }
  private func add(
    _ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", symbol: String? = nil
  ) {
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
    entry.target = self
    if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    menu.addItem(entry)
  }
  private func installMenus() {
    let root = NSMenu()
    let appItem = NSMenuItem()
    let app = NSMenu()
    appItem.submenu = app
    root.addItem(appItem)
    add(app, localized("About Flameshoter", "关于 Flameshoter"), #selector(showAbout(_:)))
    app.addItem(.separator())
    add(app, localized("Settings…", "设置…"), #selector(showPreferences(_:)), key: ",")
    let services = NSMenuItem(title: localized("Services", "服务"), action: nil, keyEquivalent: "")
    services.submenu = NSMenu()
    app.addItem(services)
    NSApp.servicesMenu = services.submenu
    app.addItem(.separator())
    let hide = NSMenuItem(
      title: localized("Hide Flameshoter", "隐藏 Flameshoter"),
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h")
    app.addItem(hide)
    app.addItem(
      NSMenuItem(
        title: localized("Show all", "全部显示"),
        action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""))
    app.addItem(.separator())
    add(app, localized("Quit Flameshoter", "退出 Flameshoter"), #selector(quit(_:)), key: "q")
    let file = NSMenu(title: localized("File", "文件"))
    let fileItem = NSMenuItem()
    fileItem.submenu = file
    root.addItem(fileItem)
    add(file, localized("Capture region", "截取区域"), #selector(capture(_:)), key: "n")
    add(file, localized("Demo canvas", "试用标注工具"), #selector(demo(_:)))
    file.addItem(.separator())
    file.addItem(
      NSMenuItem(
        title: localized("Close window", "关闭窗口"), action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"))
    let edit = NSMenu(title: localized("Edit", "编辑"))
    let editItem = NSMenuItem()
    editItem.submenu = edit
    root.addItem(editItem)
    add(edit, localized("Undo", "撤销"), #selector(undo(_:)), key: "z")
    let redo = NSMenuItem(
      title: localized("Redo", "重做"), action: #selector(redo(_:)), keyEquivalent: "z")
    redo.target = self
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(redo)
    edit.addItem(.separator())
    for (name, selector, key) in [
      (localized("Cut", "剪切"), #selector(NSText.cut(_:)), "x"),
      (localized("Copy", "复制"), #selector(NSText.copy(_:)), "c"),
      (localized("Paste", "粘贴"), #selector(NSText.paste(_:)), "v"),
      (localized("Select all", "全选"), #selector(NSText.selectAll(_:)), "a"),
    ] { edit.addItem(NSMenuItem(title: name, action: selector, keyEquivalent: key)) }
    let windows = NSMenu(title: localized("Window", "窗口"))
    let windowItem = NSMenuItem()
    windowItem.submenu = windows
    root.addItem(windowItem)
    windows.addItem(
      NSMenuItem(
        title: localized("Minimize", "最小化"), action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"))
    windows.addItem(
      NSMenuItem(
        title: localized("Zoom", "缩放"), action: #selector(NSWindow.performZoom(_:)),
        keyEquivalent: ""))
    NSApp.windowsMenu = windows
    NSApp.mainMenu = root
  }
  @objc func undo(_ sender: Any?) {
    NSApp.keyWindow?.firstResponder?.undoManager?.undo()
    for session in sessions { session.active.canvas.refresh() }
  }
  @objc func redo(_ sender: Any?) {
    NSApp.keyWindow?.firstResponder?.undoManager?.redo()
    for session in sessions { session.active.canvas.refresh() }
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(undo(_:)) {
      return NSApp.keyWindow?.firstResponder?.undoManager?.canUndo ?? false
    }
    if menuItem.action == #selector(redo(_:)) {
      return NSApp.keyWindow?.firstResponder?.undoManager?.canRedo ?? false
    }
    return true
  }
  @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }
  @objc func capture(_ sender: Any?) {
    var command = NativeCommand()
    command.delay = delay
    handle(command)
  }
  @objc private func captureDisplay(_ sender: NSMenuItem) {
    var command = NativeCommand()
    command.display = sender.tag
    handle(command)
  }
  @objc func demo(_ sender: Any?) {
    guard let url = Bundle.main.url(forResource: "demo", withExtension: "png") else {
      warning(
        localized("Demo unavailable", "示例不可用"),
        localized("The demo image is missing from this build.", "此构建缺少示例图片。"))
      return
    }
    begin(NativeCommand(), fixture: url)
  }
  func handle(_ command: NativeCommand) {
    switch command.mode {
    case "launcher":
      showLauncher(nil)
      respond(command)
    case "config":
      showPreferences(nil)
      respond(command)
    case "background": respond(command)
    default: begin(command)
    }
  }
  private func begin(_ command: NativeCommand, fixture: URL? = nil) {
    if capturePending {
      respond(command, error: localized("A capture is already starting.", "截图正在启动。"))
      return
    }
    if !Environment.shared.preferences.bool("allowMultipleGuiInstances"),
      let existing = sessions.first
    {
      existing.show()
      respond(command, error: localized("A capture is already open.", "已有截图会话打开。"))
      return
    }
    capturePending = true
    launcher?.window?.orderOut(nil)
    preferences?.window?.orderOut(nil)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.capturePending = false }
      do {
        if command.delay > 0 { try await Task.sleep(for: .milliseconds(command.delay)) }
        let frames = try await CaptureService.capture(
          displayIndex: command.display, fixture: fixture)
        if command.mode == "full" || command.mode == "screen" {
          try self.completeDirect(command, frames: frames)
          return
        }
        let session = CaptureSession(frames: frames, command: command, app: self)
        self.sessions.append(session)
        session.show()
      } catch {
        self.respond(command, error: errorMessage(error))
        if !(error is CaptureError) {
          warning(localized("Capture failed", "截图失败"), errorMessage(error))
        }
        if command.requestID == nil { self.showLauncher(nil) }
      }
    }
  }
  private func completeDirect(_ command: NativeCommand, frames: [CapturedScreen]) throws {
    guard let frame = frames.first else { throw CaptureError.display }
    let (source, size) =
      try command.mode == "full"
      ? CaptureService.combined(frames) : (frame.image, frame.logicalSize)
    var document = CaptureDocument(image: source, logicalSize: size)
    if let r = command.region {
      document.selection = CGRect(
        x: r.minX / document.scale, y: r.minY / document.scale, width: r.width / document.scale,
        height: r.height / document.scale)
    }
    let image = try ImageRenderer.render(document)
    if command.copy {
      try ImageRenderer.copy(
        image, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
        quality: Environment.shared.preferences.integer("jpegQuality"))
    }
    if command.pin { pin(image, screen: frame.screen) }
    if command.path != nil || (!command.copy && !command.raw && !command.pin) {
      if let url = try Files.save(
        image, path: command.path ?? Environment.shared.preferences.saveDirectory.path,
        filename: command.filename)
      {
        notifySaved(url)
      }
    }
    respond(command, image: image, selection: document.pixelSelection)
  }
  func sessionClosed(_ session: CaptureSession) {
    sessions.removeAll { $0 === session }
    quitIfIdle()
  }
  private func quitIfIdle() {
    if shouldQuitWhenIdle() { NSApp.terminate(nil) }
  }
  func shouldQuitWhenIdle() -> Bool {
    !preparingRestart && !capturePending
      && Environment.shared.preferences.bool("disabledTrayIcon")
      && Environment.shared.preferences.bool("autoCloseIdleDaemon")
      && sessions.isEmpty && pins.isEmpty
      && !NSApp.windows.contains(where: {
        $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
      })
  }
  func pin(_ image: CGImage, screen: NSScreen? = NSScreen.main) {
    let controller = PinWindowController(image: image, screen: screen)
    controller.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
    pins.append(controller)
    controller.show()
  }
  func respond(
    _ command: NativeCommand, image: CGImage? = nil, selection: CGRect? = nil, error: String? = nil
  ) {
    if command.requestID == nil, standaloneCapture {
      standaloneCapture = false
      var status: Int32 = error == nil ? 0 : 1
      if let error { FileHandle.standardError.write(Data((error + "\n").utf8)) }
      if command.raw, let image {
        do { FileHandle.standardOutput.write(try ImageRenderer.data(image)) } catch {
          FileHandle.standardError.write(Data((errorMessage(error) + "\n").utf8))
          status = 1
        }
      }
      if command.geometry, let selection {
        let line =
          "\(Int(selection.width))x\(Int(selection.height))+\(Int(selection.minX))+\(Int(selection.minY))\n"
        (command.raw ? FileHandle.standardError : FileHandle.standardOutput).write(Data(line.utf8))
      }
      let exitStatus = status
      DispatchQueue.main.async { exit(exitStatus) }
      return
    }
    guard let id = command.requestID, UUID(uuidString: id) != nil else { return }
    var information: [String: String] = [:]
    if let error {
      information["error"] = error
    } else if let image {
      do {
        let url = CommandBridge.resultURL(id)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try ImageRenderer.data(image).write(to: url, options: .atomic)
      } catch { information["error"] = errorMessage(error) }
    }
    if let selection {
      information["geometry"] =
        "\(Int(selection.width))x\(Int(selection.height))+\(Int(selection.minX))+\(Int(selection.minY))"
    }
    DistributedNotificationCenter.default().postNotificationName(
      CommandBridge.responseName(id), object: CommandBridge.identifier, userInfo: information,
      deliverImmediately: true)
  }
  func notify(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
  func notifyCancelled() {
    if Environment.shared.preferences.bool("showAbortNotification") {
      notify(title: localized("Capture cancelled", "截图已取消"), body: "")
    }
  }
  func notifySaved(_ url: URL) {
    item?.button?.toolTip = localized("Saved: ", "已保存：") + url.lastPathComponent
    guard Environment.shared.preferences.bool("showDesktopNotification") else { return }
    let content = UNMutableNotificationContent()
    content.title = localized("Screenshot saved", "截图已保存")
    content.body = url.path
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }
  @objc func showLauncher(_ sender: Any?) {
    if launcher == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 410),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Flameshoter"
      window.isReleasedWhenClosed = false
      window.center()
      window.setFrameAutosaveName("FlameshoterLauncher")
      let heading = label("Flameshoter", size: 34)
      heading.font = .systemFont(ofSize: 34, weight: .bold)
      let subtitle = label(
        localized("Capture, annotate, and share.", "截图、标注，轻松分享。"), secondary: true, size: 17)
      let description = label(
        localized(
          "Select a region, then annotate it with native macOS controls. Your screenshots stay on your Mac.",
          "拖动选择截图区域，再使用原生 macOS 工具进行标注。截图保存在你的 Mac 上。"), secondary: true)
      let delays = ActionPopup(
        items: [
          localized("No delay", "无延迟"), localized("1 second", "1 秒"), localized("3 seconds", "3 秒"),
          localized("5 seconds", "5 秒"),
          localized("10 seconds", "10 秒"),
        ], selected: 0
      ) { [weak self] index in self?.delay = [0, 1000, 3000, 5000, 10000][index] }
      let content = stack([
        heading, subtitle, description,
        stack([label(localized("Delay", "延迟")), delays], vertical: false),
        stack(
          [
            ActionButton(localized("Capture region", "截取区域"), symbol: "viewfinder") { [weak self] in
              self?.capture(nil)
            },
            ActionButton(localized("Settings…", "设置…"), symbol: "gearshape") { [weak self] in
              self?.showPreferences(nil)
            },
          ], vertical: false),
        ActionButton(localized("Try annotation tools", "试用标注工具"), symbol: "pencil.tip") {
          [weak self] in
          self?.demo(nil)
        },
        label(
          localized(
            "Close this window to keep Flameshoter in the menu bar.", "关闭此窗口后，Flameshoter 会继续驻留菜单栏。"
          ), secondary: true),
      ])
      let root = NSView()
      root.addSubview(content)
      NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
        content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
        content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
      ])
      window.contentView = root
      launcher = NSWindowController(window: window)
    }
    launcher?.showWindow(nil)
    launcher?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  @objc func showPreferences(_ sender: Any?) {
    for session in sessions { session.hide() }
    if preferences == nil { preferences = PreferencesController() }
    preferences?.showWindow(nil)
    preferences?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  @objc func showAbout(_ sender: Any?) {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Flameshoter",
      .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "0.2.4",
      .version: localized(
        "Native Swift / AppKit · Based on Flameshot", "原生 Swift / AppKit · 基于 Flameshot"),
      .credits: NSAttributedString(
        string:
          "GPL-3.0-or-later\nFlameshot by Alejandro Sirgo Rica and contributors\nhttps://github.com/Word2VecT/flameshoter"
      ),
    ])
    NSApp.activate()
  }
}
