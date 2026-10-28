// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

@MainActor final class CaptureWindow: NSWindow {
  weak var canvas: CanvasView?
  weak var captureToolbar: CaptureToolbar?
  weak var captureSharing: CaptureSharing?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard self === NSApp.keyWindow else { return super.performKeyEquivalent(with: event) }
    if let captureSharing {
      if event.keyCode == 53 { captureSharing.cancelPicker() }
      return true
    }
    if captureToolbar?.isInspectorShown == true {
      if event.keyCode == 53 {
        captureToolbar?.dismissInspector()
        return true
      }
      return super.performKeyEquivalent(with: event)
    }
    if canvas?.handleKey(event) == true { return true }
    return super.performKeyEquivalent(with: event)
  }
}
@MainActor final class CaptureSession {
  struct Surface {
    let screen: NSScreen
    let window: CaptureWindow
    let canvas: CanvasView
    let toolbar: CaptureToolbar
    let hint: PassiveGlass
  }
  private(set) var surfaces: [Surface] = []
  private(set) var activeIndex = 0
  var active: Surface { surfaces[activeIndex] }
  let command: NativeCommand
  weak var app: AppController?
  private var closing = false
  private var sharing: CaptureSharing?
  private var exporting = false
  init(frames: [CapturedScreen], command: NativeCommand, app: AppController) {
    self.command = command
    self.app = app
    for (index, frame) in frames.enumerated() {
      let nativeFullscreen = Environment.shared.preferences.bool("useNativeFullscreen")
      let window = CaptureWindow(
        contentRect: frame.screen.frame,
        styleMask: nativeFullscreen ? [.titled, .resizable, .fullSizeContentView] : .borderless,
        backing: .buffered, defer: false)
      window.title = localized("Flameshoter Capture", "Flameshoter 截图")
      window.setAccessibilitySubrole(.standardWindow)
      window.isReleasedWhenClosed = false
      window.level = nativeFullscreen ? .normal : .statusBar
      window.collectionBehavior = nativeFullscreen ? [.fullScreenPrimary] : [.fullScreenAuxiliary]
      window.acceptsMouseMovedEvents = true
      window.backgroundColor = .black
      let canvas = CanvasView(frame: frame)
      canvas.autoresizingMask = [.width, .height]
      window.canvas = canvas
      window.contentView = canvas
      let toolbar = CaptureToolbar(canvas: canvas, command: command)
      window.captureToolbar = toolbar
      let hint = PassiveGlass()
      hint.style = .regular
      hint.cornerRadius = 24
      let heading = label(localized("Drag to select a capture region", "拖动选择截图区域"), size: 17)
      heading.font = .systemFont(ofSize: 17, weight: .semibold)
      let detail = label(
        localized(
          "⌘C Copy · ⌘S Save · Space Tools · Esc Cancel", "⌘C 复制 · ⌘S 保存 · 空格 工具设置 · Esc 取消"),
        secondary: true, size: 12)
      let messages = stack([heading, detail], spacing: 6)
      messages.widthAnchor.constraint(equalToConstant: 420).isActive = true
      hint.contentView = padded(messages, inset: 12)
      canvas.addSubview(hint)
      surfaces.append(
        Surface(screen: frame.screen, window: window, canvas: canvas, toolbar: toolbar, hint: hint))
      canvas.onAction = { [weak self] action in self?.perform(action, on: index) }
      canvas.onInteract = { [weak self] in self?.activate(index) ?? false }
      canvas.onChange = { [weak self] in self?.update(index) }
      canvas.onInspector = { [weak toolbar] in toolbar?.toggleInspector() }
      canvas.onRegionSettled = { [weak self] in
        guard let self else { return }
        self.update(index)
        if self.command.acceptOnSelect { self.perform(.accept, on: index) }
      }
    }
    if let screen = frames.firstIndex(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) {
      activeIndex = screen
    }
    let surface = active
    if let region = command.region {
      surface.canvas.setSelection(
        CGRect(
          x: region.minX / surface.canvas.document.scale,
          y: region.minY / surface.canvas.document.scale,
          width: region.width / surface.canvas.document.scale,
          height: region.height / surface.canvas.document.scale))
    } else if command.lastRegion, let rect = Self.savedRegion() {
      surface.canvas.setSelection(rect)
    }
  }
  func show() {
    NSApp.activate()
    for (index, surface) in surfaces.enumerated() {
      surface.window.orderFrontRegardless()
      update(index)
    }
    active.window.makeKeyAndOrderFront(nil)
    active.window.makeFirstResponder(active.canvas)
    if Environment.shared.preferences.bool("useNativeFullscreen"),
      !active.window.styleMask.contains(.fullScreen)
    {
      active.window.toggleFullScreen(nil)
    }
    NSColorPanel.shared.level = NSWindow.Level(rawValue: active.window.level.rawValue + 2)
    if command.acceptOnSelect, active.canvas.document.selection != nil {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.perform(.accept, on: self.activeIndex)
      }
    }
  }
  func activate(_ index: Int) -> Bool {
    guard index != activeIndex else { return true }
    let previous = active
    if !previous.canvas.document.annotations.isEmpty
      && Environment.shared.preferences.bool("showQuitPrompt")
    {
      hide()
      let discard = confirmDiscard()
      show()
      if !discard { return false }
    }
    previous.canvas.setSelection(nil)
    activeIndex = index
    return true
  }
  func update(_ index: Int) {
    guard surfaces.indices.contains(index) else { return }
    let surface = surfaces[index]
    surface.toolbar.refresh()
    let help =
      Environment.shared.preferences.bool("showHelp") && surface.canvas.document.selection == nil
      && surface.window.isVisible
    if help {
      let size = surface.hint.contentView?.fittingSize ?? NSSize(width: 440, height: 90)
      surface.hint.frame = CGRect(
        x: surface.canvas.bounds.midX - size.width / 2,
        y: surface.canvas.bounds.midY - size.height / 2, width: size.width, height: size.height)
      surface.hint.isHidden = false
    } else {
      surface.hint.isHidden = true
    }
  }
  func hide() {
    for surface in surfaces {
      surface.toolbar.hide()
      surface.hint.isHidden = true
      surface.window.orderOut(nil)
    }
    NSColorPanel.shared.orderOut(nil)
  }
  func close(cancelled: Bool = false) {
    guard !closing else { return }
    closing = true
    sharing?.close()
    sharing = nil
    if Environment.shared.preferences.bool("saveLastRegion"),
      let r = active.canvas.document.selection
    {
      Environment.shared.settings.set("lastRegion", NSStringFromRect(r))
    }
    for surface in surfaces {
      surface.canvas.textEditor?.removeFromSuperview()
      surface.toolbar.close()
      surface.hint.removeFromSuperview()
      surface.window.close()
    }
    NSColorPanel.shared.orderOut(nil)
    NSColorPanel.shared.level = .floating
    if cancelled {
      app?.respond(command, error: localized("Capture cancelled", "截图已取消"))
      app?.notifyCancelled()
    }
    app?.sessionClosed(self)
  }
  private static func savedRegion() -> CGRect? {
    let string = Environment.shared.preferences.string("lastRegion")
    guard !string.isEmpty else { return nil }
    let rect = NSRectFromString(string)
    return rect.isEmpty ? nil : rect
  }
  private func share(_ image: CGImage) {
    guard sharing == nil else { return }
    let controller = CaptureSharing(image: image)
    sharing = controller
    let windowLevels = surfaces.map { $0.window.level }
    // Let the system share sheet appear above the screenshot overlay.
    for surface in surfaces {
      surface.window.captureSharing = controller
      surface.window.level = .normal
    }
    controller.onBegin = { [weak self] in self?.hide() }
    controller.onFinish = { [weak self] result in
      // Finish dispatching ShareKit's dismiss event before accepting capture keys again.
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closing else { return }
        self.sharing = nil
        for (surface, level) in zip(self.surfaces, windowLevels) {
          surface.window.captureSharing = nil
          surface.window.level = level
        }
        switch result {
        case .success(true):
          self.app?.respond(
            self.command, image: image, selection: self.active.canvas.document.pixelSelection)
          self.close()
        case .success(false): self.show()
        case .failure(let error):
          let failure = error as NSError
          if !(failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError) {
            warning(localized("Unable to share capture", "无法分享截图"), errorMessage(error))
          }
          self.show()
        }
      }
    }
    let anchor = active.toolbar.button(for: .share) ?? active.canvas
    controller.show(
      relativeTo: anchor === active.canvas ? active.canvas.document.selection! : anchor.bounds,
      of: anchor)
  }
  func perform(_ tool: Tool, on index: Int) {
    guard !closing, !exporting else { return }
    exporting = true
    Task {
      defer { exporting = false }
      await performAction(tool, on: index)
    }
  }
  private func performAction(_ tool: Tool, on index: Int) async {
    activeIndex = index
    let canvas = active.canvas
    if tool == .exit {
      if !canvas.document.annotations.isEmpty, Environment.shared.preferences.bool("showQuitPrompt")
      {
        hide()
        if !confirmDiscard() {
          show()
          return
        }
      }
      close(cancelled: true)
      return
    }
    if tool == .select {  // Native screen color sampler, invoked by the pick-color shortcut.
      hide()
      if let color = await NSColorSampler().sample() {
        Environment.shared.settings.set("drawColor", RGBA(color).hex)
        canvas.applyStyle { $0.color = RGBA(color) }
      }
      show()
      return
    }
    guard canvas.document.selection != nil else { return }
    do {
      let image = try canvas.rendered()
      let selection = canvas.document.pixelSelection
      switch tool {
      case .share:
        share(image)
        return
      case .copy:
        hide()
        try await ImageRenderer.copy(
          image, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
          quality: Environment.shared.preferences.integer("jpegQuality"),
          optimize: Environment.shared.preferences.bool("losslessCompression"))
        if Environment.shared.preferences.bool("saveAfterCopy") {
          _ = try await Files.save(image, path: command.path, filename: command.filename)
        }
      case .save:
        hide()
        guard let url = try await Files.save(image, path: command.path, filename: command.filename)
        else {
          show()
          return
        }
        app?.notifySaved(url)
      case .pin:
        app?.pin(image, screen: active.screen)
      case .openWith:
        hide()
        guard try await Files.openWith(image) else {
          show()
          return
        }
      case .accept:
        if let path = command.path {
          hide()
          guard let url = try await Files.save(image, path: path, filename: command.filename) else {
            show()
            return
          }
          app?.notifySaved(url)
        }
        if command.copy || (!command.raw && command.path == nil && !command.pin) {
          try await ImageRenderer.copy(
            image, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
            quality: Environment.shared.preferences.integer("jpegQuality"),
            optimize: Environment.shared.preferences.bool("losslessCompression"))
        }
        if command.pin { app?.pin(image, screen: active.screen) }
      default: return
      }
      app?.respond(command, image: image, selection: selection)
      close()
    } catch {
      hide()
      warning(localized("Capture failed", "截图操作失败"), errorMessage(error))
      show()
    }
  }
}
