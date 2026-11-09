// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import UserNotifications

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var initialCommand: NativeCommand?
  private var item: NSStatusItem?
  private var preferences: PreferencesController?
  private var sessions: [CaptureSession] = []
  private var pins: [PinWindowController] = []
  private var contentPins: [ContentPinController] = []
  private enum ClosedPin {
    case image(PinWindowController), content(ContentPinController), archived(ArchivedPin)
    var archiveID: UUID {
      switch self {
      case .image(let pin): return pin.archiveID
      case .content(let pin): return pin.archiveID
      case .archived(let pin): return pin.id
      }
    }
  }
  private var closedPins: [ClosedPin] = []
  private var pendingPinUpdates: [UUID: Task<Void, Never>] = [:]
  private var dirtyPinText: Set<UUID> = []
  private var pinArchiveErrorShown = false
  private var regionHistoryErrorShown = false
  private var captureHistoryErrorShown = false
  private var pinArchiveFailure: Error?
  private var terminating = false
  private lazy var pinArchive = PinArchive(
    directory: Environment.shared.settings.url.deletingLastPathComponent().appendingPathComponent("Pins", isDirectory: true),
    onError: { [weak self] error in
      Task { @MainActor [weak self] in self?.showPinArchiveError(error) }
    })
  private var recognitionWindows: [RecognitionWindowController] = []
  private var translationWindows: [TranslationWindowController] = []
  private var tableWindows: [TableRecognitionWindowController] = []
  private var observers: [NSObjectProtocol] = []
  private var commandObserver: NSObjectProtocol?
  private let hotkey = GlobalHotkey()
  private let pinClipboardHotkey = GlobalHotkey(identifier: 2)
  private let restorePinHotkey = GlobalHotkey(identifier: 3)
  private var capturePending = false
  private var preparingRestart = false
  private var restartTask: Process?
  private var standaloneCapture: Bool
  private var canUseGlobalHotkeys: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["FLAMESHOTER_TEST_CONFIG"] == nil || env["FLAMESHOTER_TEST_GLOBAL_HOTKEYS"] == "1"
  }
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
      self?.trimPinHistory()
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
    restorePinHistory()
    if let command = initialCommand { handle(command) }
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
    return false
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateLater }
    if recordingPreventsExit() { return .terminateCancel }
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
    terminating = true
    for task in pendingPinUpdates.values { task.cancel() }
    pendingPinUpdates.removeAll()
    dirtyPinText.removeAll()
    for pin in pins { persist(pin) }
    for pin in contentPins { persist(pin, includeText: true) }
    for pin in closedPins {
      switch pin {
      case .image(let controller): persist(controller)
      case .content(let controller): persist(controller, includeText: true)
      case .archived: break
      }
    }
    Environment.shared.captureHistory.flush { [weak self] _ in
      Task { @MainActor [weak self] in self?.finishTermination() }
    }
    return .terminateLater
  }
  private func finishTermination() {
    pinArchive.flush { [weak self] result in
      Task { @MainActor [weak self] in
        if case .success = result, self?.pinArchiveFailure == nil {
          NSApp.reply(toApplicationShouldTerminate: true)
        } else {
          let alert = NSAlert()
          alert.messageText = localized("Pin history could not be saved", "贴图历史保存失败")
          alert.informativeText = localized(
            "Save important pins separately before quitting, or continue and discard unsaved history.",
            "退出前请另存重要贴图；继续退出可能丢失未保存的贴图历史。")
          alert.addButton(withTitle: localized("Keep using Flameshoter", "继续使用"))
          alert.addButton(withTitle: localized("Quit anyway", "仍然退出"))
          let shouldQuit = alert.runModal() == .alertSecondButtonReturn
          self?.terminating = shouldQuit
          if !shouldQuit { self?.cancelRestart() }
          NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
      }
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let commandObserver {
      DistributedNotificationCenter.default().removeObserver(commandObserver)
    }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
  func prepareForRestart() -> Bool {
    if recordingPreventsExit() { return false }
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
  func trackRestart(_ task: Process) { restartTask = task }
  func cancelRestart() {
    if restartTask?.isRunning == true { restartTask?.terminate() }
    restartTask = nil
    preparingRestart = false
  }
  private func recordingPreventsExit() -> Bool {
    guard sessions.contains(where: { $0.hasUnsavedRecording }) else { return false }
    warning(
      localized("Recording in progress", "录屏尚未完成"),
      localized("Stop and save or cancel the recording before quitting or restarting.", "请先停止并保存或取消录屏，再退出或重新启动。"))
    return true
  }
  func assignGlobalShortcut(_ shortcut: Shortcut?, for name: String = "TAKE_SCREENSHOT") -> Bool {
    guard canUseGlobalHotkeys else { return true }
    let handler = name == "PIN_CLIPBOARD" ? pinClipboardHotkey : name == "RESTORE_PIN" ? restorePinHotkey : hotkey
    let old = Environment.shared.preferences.shortcut(name)
    if handler.register(shortcut) == noErr { return true }
    _ = handler.register(old)
    warning(
      localized("Global shortcut unavailable", "全局快捷键不可用"),
      localized(
        "Another application may be using this combination. Choose a different shortcut.",
        "此组合键可能已被其他应用占用，请选择其他组合键。"))
    return false
  }
  private func configureHotkey() {
    guard canUseGlobalHotkeys else { return }
    hotkey.invoke = { [weak self] in self?.capture(nil) }
    pinClipboardHotkey.invoke = { [weak self] in self?.pinClipboard(nil) }
    restorePinHotkey.invoke = { [weak self] in self?.restoreClosedPin(nil) }
    for (name, handler) in [("TAKE_SCREENSHOT", hotkey), ("PIN_CLIPBOARD", pinClipboardHotkey),
                            ("RESTORE_PIN", restorePinHotkey)] {
      if handler.register(Environment.shared.preferences.shortcut(name)) != noErr {
        warning(
          localized("Global shortcut unavailable", "全局快捷键不可用"),
          localized(
            "Another application may be using this combination. Choose a different shortcut in Settings.",
            "此组合键可能已被其他应用占用，请在设置中选择其他快捷键。"))
      }
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
    add(menu, localized("Pin clipboard", "置顶剪贴板"), #selector(pinClipboard(_:)), symbol: "pin", shortcut: "PIN_CLIPBOARD")
    add(menu, localized("Restore last closed pin", "恢复上次关闭的贴图"), #selector(restoreClosedPin(_:)), shortcut: "RESTORE_PIN")
    menu.addItem(.separator())
    add(menu, localized("Settings…", "设置…"), #selector(showPreferences(_:)), symbol: "gearshape")
    add(menu, localized("About Flameshoter", "关于 Flameshoter"), #selector(showAbout(_:)))
    menu.addItem(.separator())
    add(menu, localized("Quit Flameshoter", "退出 Flameshoter"), #selector(quit(_:)), key: "q")
    item?.menu = menu
  }
  private func add(
    _ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", symbol: String? = nil,
    shortcut: String? = nil
  ) {
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
    entry.target = self
    if let shortcut, let binding = Environment.shared.preferences.shortcut(shortcut),
      let character = Shortcut.names[binding.keyCode], character.count == 1,
      character.first?.isASCII == true
    {
      entry.keyEquivalent = character.lowercased()
      entry.keyEquivalentModifierMask = binding.modifiers.intersection(Shortcut.relevant)
    }
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
    add(file, localized("Pin clipboard", "置顶剪贴板"), #selector(pinClipboard(_:)), shortcut: "PIN_CLIPBOARD")
    add(file, localized("Restore last closed pin", "恢复上次关闭的贴图"), #selector(restoreClosedPin(_:)), shortcut: "RESTORE_PIN")
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
    if menuItem.action == #selector(restoreClosedPin(_:)) { return !closedPins.isEmpty }
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
    handle(NativeCommand())
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
    preferences?.window?.orderOut(nil)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.capturePending = false }
      do {
        if command.delay > 0 { try await Task.sleep(for: .milliseconds(command.delay)) }
        let frames = try await CaptureService.capture(
          displayIndex: command.display, fixture: fixture)
        if command.mode == "full" || command.mode == "screen" {
          try await self.completeDirect(command, frames: frames)
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
      }
    }
  }
  private func completeDirect(_ command: NativeCommand, frames: [CapturedScreen]) async throws {
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
      try await ImageRenderer.copy(
        image, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
        quality: Environment.shared.preferences.integer("jpegQuality"),
        optimize: Environment.shared.preferences.bool("losslessCompression"))
    }
    if command.pin { pin(image, screen: frame.screen) }
    if command.path != nil || (!command.copy && !command.raw && !command.pin) {
      if let url = try await Files.save(
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
      && sessions.isEmpty && pins.isEmpty && contentPins.isEmpty
      && !NSApp.windows.contains(where: {
        $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
      })
  }
  func pin(_ image: CGImage, screen: NSScreen? = NSScreen.main) {
    standaloneCapture = false
    let controller = PinWindowController(image: image, screen: screen)
    configure(controller)
    pins.append(controller)
    controller.show()
    let record = pinRecord(controller)
    pinArchive.add(record) { try ImageEncoder.data(image) }
  }
  private func configure(_ controller: PinWindowController) {
    controller.onClose = { [weak self] closed in
      guard let self, !self.terminating else { return }
      self.cancelPinUpdate(closed.archiveID)
      closed.closed = Date()
      self.pins.removeAll { $0 === closed }
      self.closedPins.append(.image(closed))
      self.persist(closed, releaseWhenSaved: true)
      self.trimPinHistory()
    }
    controller.onChange = { [weak self] pin in self?.schedulePinUpdate(pin) }
    controller.onRecognize = { [weak self] image, kind in self?.recognize(image, kind: kind) }
    controller.onTranslate = { [weak self] image in self?.translate(image) }
    controller.onRecognizeTable = { [weak self] image in self?.recognizeTable(image) }
  }
  private func pin(_ content: ContentPin) {
    let controller = ContentPinController(content: content)
    configure(controller)
    contentPins.append(controller)
    controller.show()
    do {
      let data = try controller.archivedPayload().1
      pinArchive.add(pinRecord(controller)) { data }
    } catch { showPinArchiveError(error) }
  }
  private func configure(_ controller: ContentPinController) {
    controller.onClose = { [weak self] closed in
      guard let self, !self.terminating else { return }
      self.cancelPinUpdate(closed.archiveID)
      closed.closed = Date()
      self.contentPins.removeAll { $0 === closed }
      self.closedPins.append(.content(closed))
      self.persist(closed, includeText: true, releaseWhenSaved: true)
      self.trimPinHistory()
    }
    controller.onChange = { [weak self] pin, contentChanged in
      self?.schedulePinUpdate(pin, contentChanged: contentChanged)
    }
  }
  @objc func pinClipboard(_ sender: Any?) {
    let env = ProcessInfo.processInfo.environment
    let board: NSPasteboard
    if env["FLAMESHOTER_TEST_CONFIG"] != nil, let name = env["FLAMESHOTER_TEST_PASTEBOARD"] {
      board = NSPasteboard(name: NSPasteboard.Name(name))
    } else { board = .general }
    guard pinClipboardContents(of: board) else {
      warning(localized("Nothing to pin", "没有可置顶的内容"),
              localized("Copy an image, text, color or file first.", "请先复制图片、文字、颜色或文件。"))
      return
    }
  }
  @discardableResult func pinClipboardContents(of board: NSPasteboard) -> Bool {
    let contents = ClipboardPin.contents(of: board)
    guard !contents.isEmpty else { return false }
    for content in contents {
      switch content {
      case .image(let image): pin(image)
      case .animated(let data, let type): pin(.animated(data, type))
      case .text(let text): pin(.text(text))
      case .color(let color, let original): pin(.color(color, original))
      case .file(let url): pin(.file(url))
      }
    }
    return true
  }
  @objc func restoreClosedPin(_ sender: Any?) {
    guard let last = closedPins.popLast() else { return }
    switch last {
    case .image(let controller):
      controller.closed = nil; pins.append(controller); controller.show(); persist(controller)
    case .content(let controller):
      controller.closed = nil; contentPins.append(controller); controller.show(); persist(controller, includeText: false)
    case .archived(let record): restoreArchivedPin(record, reopeningClosed: true)
    }
  }
  private func trimPinHistory() {
    let limit = Environment.shared.preferences.integer("pinHistoryLimit")
    if closedPins.count > limit {
      let count = closedPins.count - limit
      let ids = Set(closedPins.prefix(count).map(\.archiveID))
      closedPins.removeFirst(count)
      pinArchive.remove(ids)
    }
  }
  private func pinRecord(_ pin: PinWindowController) -> ArchivedPin {
    PinPersistence.record(id: pin.archiveID, kind: .image, created: pin.created, closed: pin.closed, window: pin.window)
  }
  private func pinRecord(_ pin: ContentPinController) -> ArchivedPin {
    PinPersistence.record(id: pin.archiveID, kind: pin.archiveKind, created: pin.created, closed: pin.closed, window: pin.window)
  }
  private func releaseClosedPinWhenSaved() -> @Sendable (Result<ArchivedPin, Error>) -> Void {
    { [weak self] result in
      guard case .success(let record) = result else { return }
      Task { @MainActor [weak self] in
        guard let self, let index = self.closedPins.firstIndex(where: { $0.archiveID == record.id }) else { return }
        self.closedPins[index] = .archived(record)
      }
    }
  }
  private func persist(_ pin: PinWindowController, releaseWhenSaved: Bool = false) {
    pinArchive.update(pinRecord(pin), completion: releaseWhenSaved ? releaseClosedPinWhenSaved() : nil)
  }
  private func persist(_ pin: ContentPinController, includeText: Bool, releaseWhenSaved: Bool = false) {
    do {
      let payload = includeText && pin.archiveKind == .text ? try pin.archivedPayload().1 : nil
      pinArchive.update(pinRecord(pin), payload: payload, completion: releaseWhenSaved ? releaseClosedPinWhenSaved() : nil)
    } catch { showPinArchiveError(error) }
  }
  private func cancelPinUpdate(_ id: UUID) {
    pendingPinUpdates.removeValue(forKey: id)?.cancel()
    dirtyPinText.remove(id)
  }
  private func schedulePinUpdate(_ pin: PinWindowController) {
    guard !terminating else { return }
    let id = pin.archiveID
    pendingPinUpdates[id]?.cancel()
    pendingPinUpdates[id] = Task { [weak self, weak pin] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, let self, let pin else { return }
      self.pendingPinUpdates.removeValue(forKey: id)
      self.persist(pin)
    }
  }
  private func schedulePinUpdate(_ pin: ContentPinController, contentChanged: Bool) {
    guard !terminating else { return }
    let id = pin.archiveID
    if contentChanged { dirtyPinText.insert(id) }
    pendingPinUpdates[id]?.cancel()
    pendingPinUpdates[id] = Task { [weak self, weak pin] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, let self, let pin else { return }
      self.pendingPinUpdates.removeValue(forKey: id)
      self.persist(pin, includeText: self.dirtyPinText.remove(id) != nil)
    }
  }
  private func restorePinHistory() {
    pinArchive.load { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, !self.terminating else { return }
        switch result {
        case .failure(let error): self.showPinArchiveError(error)
        case .success(let entries):
          var restoredClosed: [ClosedPin] = []
          let keepOpen = Environment.shared.preferences.bool("restoreOpenPins")
          let ordered = entries.sorted {
            ($0.closed ?? (keepOpen ? .distantPast : .distantFuture))
              < ($1.closed ?? (keepOpen ? .distantPast : .distantFuture))
          }
          for var record in ordered {
            if record.closed == nil && keepOpen {
              self.restoreArchivedPin(record, reopeningClosed: false)
            } else {
              if record.closed == nil { record.closed = Date(); self.pinArchive.update(record) }
              restoredClosed.append(.archived(record))
            }
          }
          self.closedPins.insert(contentsOf: restoredClosed, at: 0)
          self.trimPinHistory()
        }
      }
    }
  }
  private func restoreArchivedPin(_ original: ArchivedPin, reopeningClosed: Bool) {
    pinArchive.payload(for: original.id) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, !self.terminating else { return }
        do {
          let loaded = try result.get()
          let record = loaded.record
          if record.kind == .image {
            let pin = PinWindowController(image: try PinPersistence.image(loaded.data), id: record.id, created: record.created)
            PinPersistence.restoreWindow(pin.window, from: record)
            self.configure(pin)
            self.pins.append(pin)
            pin.show()
            if reopeningClosed { self.persist(pin) }
          } else {
            let content = try PinPersistence.content(record.kind, data: loaded.data)
            let pin = ContentPinController(content: content, id: record.id, created: record.created)
            PinPersistence.restoreWindow(pin.window, from: record)
            self.configure(pin)
            self.contentPins.append(pin)
            pin.show()
            if reopeningClosed { self.persist(pin, includeText: false) }
          }
        } catch {
          if reopeningClosed { self.closedPins.append(.archived(original)); self.trimPinHistory() }
          self.showPinArchiveError(error)
        }
      }
    }
  }
  private func showPinArchiveError(_ error: Error) {
    pinArchiveFailure = error
    guard !pinArchiveErrorShown, !terminating else { return }
    pinArchiveErrorShown = true
    warning(
      localized("Unable to save or restore pin history", "无法保存或恢复贴图历史"),
      localized("Existing history was left in place. ", "已有历史文件已保留。") + errorMessage(error))
  }
  func showRegionHistoryError(_ error: Error) {
    guard !regionHistoryErrorShown else { return }
    regionHistoryErrorShown = true
    warning(
      localized("Unable to read or save capture region history", "无法读取或保存截图区域历史"),
      localized("Existing history was left in place. ", "已有历史文件已保留。") + errorMessage(error))
  }
  func showCaptureHistoryError(_ error: Error) {
    guard !captureHistoryErrorShown else { return }
    captureHistoryErrorShown = true
    warning(
      localized("Unable to read or save screenshot history", "无法读取或保存截图内容历史"),
      localized("Existing history was left in place. ", "已有历史文件已保留。") + errorMessage(error))
  }
  func recognize(_ image: CGImage, kind: RecognitionKind) {
    // An interactive CLI capture must stay alive while its result window is open.
    standaloneCapture = false
    let controller = RecognitionWindowController(image: image, kind: kind)
    controller.onClose = { [weak self] closed in
      self?.recognitionWindows.removeAll { $0 === closed }
    }
    recognitionWindows.append(controller)
    controller.show()
  }
  func translate(_ image: CGImage) {
    standaloneCapture = false
    let controller = TranslationWindowController(image: image)
    controller.onClose = { [weak self] closed in
      self?.translationWindows.removeAll { $0 === closed }
    }
    translationWindows.append(controller)
    controller.show()
  }
  func recognizeTable(_ image: CGImage) {
    standaloneCapture = false
    let controller = TableRecognitionWindowController(image: image)
    controller.onClose = { [weak self] closed in self?.tableWindows.removeAll { $0 === closed } }
    tableWindows.append(controller)
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
      Environment.shared.captureHistory.flush { _ in exit(exitStatus) }
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
        as? String ?? "0.3.9",
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
