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
  private var longCapture: LongCaptureSession?
  private var recording: ScreenRecordingSession?
  private var regionHistoryIndices: [Int: Int] = [:]
  private struct CaptureDraft {
    let selection: CGRect?
    let annotations: [Annotation]
    let edits: UndoManager
  }
  private struct CaptureNavigation {
    var live: CaptureDocument
    var liveEdits: UndoManager
    let entries: [CaptureHistoryEntry]
    var index: Int?
    var drafts: [UUID: CaptureDraft] = [:]
  }
  private var captureNavigation: [Int: CaptureNavigation] = [:]
  private var loadingCaptureHistory = false
  var hasUnsavedRecording: Bool { recording?.hasUnsavedRecording ?? false }
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
      canvas.onCopyColor = { [weak self] value in
        guard let self else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        let expectsImage = self.command.copy || self.command.raw || self.command.path != nil
          || self.command.pin || self.command.geometry
        self.app?.respond(self.command, error: expectsImage
          ? localized("Color copied; capture cancelled.", "已复制颜色，截图已取消。") : nil)
        self.close()
      }
      canvas.onRegionSettled = { [weak self] in
        guard let self else { return }
        self.regionHistoryIndices.removeValue(forKey: index)
        self.update(index)
        if self.command.acceptOnSelect { self.perform(.accept, on: index) }
      }
      canvas.onRegionHistory = { [weak self] direction in self?.cycleRegion(on: index, direction: direction) }
      canvas.onCaptureHistory = { [weak self] direction in self?.cycleCapture(on: index, direction: direction) }
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
    guard longCapture == nil && recording == nil else { return }
    NSApp.activate()
    for (index, surface) in surfaces.enumerated() {
      surface.window.orderFrontRegardless()
      update(index)
    }
    active.window.makeKeyAndOrderFront(nil)
    active.window.makeFirstResponder(active.canvas)
    active.canvas.updateAutomaticSelectionAtMouse()
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
      && surface.canvas.suggestedSelection == nil
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
    longCapture?.invalidate()
    longCapture = nil
    recording?.invalidate()
    recording = nil
    var regionError: Error?
    if !cancelled, let rectangle = active.canvas.document.selection {
      do {
        try Environment.shared.regionHistory.record(
          display: RegionHistory.displayIdentifier(active.screen), rectangle: rectangle,
          limit: Environment.shared.preferences.integer("regionHistoryLimit"))
      } catch { regionError = error }
    }
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
    if let regionError { app?.showRegionHistoryError(regionError) }
  }
  private func cycleRegion(on index: Int, direction: Int) {
    guard surfaces.indices.contains(index), activate(index) else { return }
    let surface = surfaces[index]
    guard surface.canvas.historySnapshot == nil else { NSSound.beep(); return }
    let history = Environment.shared.regionHistory
    let limit = Environment.shared.preferences.integer("regionHistoryLimit")
    guard limit > 0 else { NSSound.beep(); return }
    if let error = history.loadError { app?.showRegionHistoryError(error); return }
    let regions = history.regions(
      display: RegionHistory.displayIdentifier(surface.screen), bounds: surface.canvas.bounds,
      limit: limit)
    guard !regions.isEmpty else { NSSound.beep(); return }
    let current = regionHistoryIndices[index]
    let target = current.map { ($0 + direction + regions.count) % regions.count }
      ?? (direction < 0 ? regions.count - 1 : 0)
    regionHistoryIndices[index] = target
    surface.canvas.setSelection(regions[target])
  }
  private func cycleCapture(on index: Int, direction: Int) {
    guard !loadingCaptureHistory, surfaces.indices.contains(index), activate(index) else { return }
    let limit = Environment.shared.preferences.integer("captureHistoryLimit")
    guard limit > 0 else { NSSound.beep(); return }
    loadingCaptureHistory = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.loadingCaptureHistory = false }
      let surface = self.surfaces[index]
      let canvas = surface.canvas
      do {
        if self.captureNavigation[index] == nil {
          let result: Result<[CaptureHistoryEntry], Error> = await withCheckedContinuation { continuation in
            Environment.shared.captureHistory.list(
              display: RegionHistory.displayIdentifier(surface.screen), bounds: canvas.bounds,
              scale: canvas.document.scale, limit: limit
            ) { continuation.resume(returning: $0) }
          }
          let entries = try result.get()
          guard !entries.isEmpty else { NSSound.beep(); return }
          guard !self.closing, self.activeIndex == index else { return }
          canvas.commitText()
          self.captureNavigation[index] = CaptureNavigation(
            live: canvas.document, liveEdits: canvas.edits, entries: entries)
        }
        guard var navigation = self.captureNavigation[index] else { return }
        let count = navigation.entries.count
        let current = navigation.index ?? count
        let target = (current + direction + count + 1) % (count + 1)
        var snapshot: CaptureHistorySnapshot?
        var background: CGImage?
        if target < count {
          let id = navigation.entries[target].id
          let result: Result<CaptureHistorySnapshot, Error> = await withCheckedContinuation { continuation in
            Environment.shared.captureHistory.snapshot(id: id) { continuation.resume(returning: $0) }
          }
          snapshot = try result.get()
          let loaded = snapshot!
          let liveImage = navigation.live.image
          background = try await Task.detached(priority: .userInitiated) {
            try loaded.composite(over: liveImage)
          }.value
        }
        guard !self.closing, self.activeIndex == index else { return }
        canvas.commitText()
        if let current = navigation.index {
          navigation.drafts[navigation.entries[current].id] = CaptureDraft(
            selection: canvas.document.selection, annotations: canvas.document.annotations, edits: canvas.edits)
        } else {
          navigation.live = canvas.document
          navigation.liveEdits = canvas.edits
        }
        if let snapshot, let background {
          var document = CaptureDocument(
            image: background, logicalSize: navigation.live.logicalSize, undoLimit: navigation.live.undoLimit)
          if let draft = navigation.drafts[snapshot.entry.id] {
            document.selection = draft.selection
            document.replaceAnnotations(draft.annotations, recordingUndo: false)
          } else {
            document.selection = snapshot.entry.rectangle
            let origin = snapshot.entry.rectangle.origin
            document.replaceAnnotations(snapshot.entry.annotations.map { original in
              var annotation = original
              annotation.move(by: CGSize(width: origin.x, height: origin.y))
              return annotation
            }, recordingUndo: false)
          }
          navigation.index = target
          self.captureNavigation[index] = navigation
          surface.window.title = localized("Screenshot history", "截图历史")
          canvas.replaceDocument(document, history: snapshot, edits: navigation.drafts[snapshot.entry.id]?.edits)
        } else {
          navigation.index = nil
          self.captureNavigation[index] = navigation
          surface.window.title = localized("Flameshoter Capture", "Flameshoter 截图")
          canvas.replaceDocument(navigation.live, edits: navigation.liveEdits)
        }
      } catch { self.app?.showCaptureHistoryError(error) }
    }
  }
  private func recordCapture(_ canvas: CanvasView) {
    let limit = Environment.shared.preferences.integer("captureHistoryLimit")
    guard limit > 0 else { return }
    let source = canvas.sourceDocument()
    do {
      let snapshot = try CaptureHistorySnapshot.make(
        document: source.document, display: RegionHistory.displayIdentifier(active.screen), origin: source.origin)
      Environment.shared.captureHistory.record(snapshot, limit: limit)
    } catch { app?.showCaptureHistoryError(error) }
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
          self.recordCapture(self.active.canvas)
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
    if tool == .screenRecording {
      guard !command.copy, !command.raw, command.path == nil, !command.pin, !command.geometry else { return }
      if !canvas.document.annotations.isEmpty, Environment.shared.preferences.bool("showQuitPrompt") {
        hide()
        if !confirmDiscard() { show(); return }
      }
      let selection = canvas.document.selection!
      hide()
      let controller = ScreenRecordingSession(screen: active.screen, selection: selection)
      recording = controller
      controller.onFinish = { [weak self] saved in
        guard let self else { return }
        self.recording = nil
        self.app?.respond(self.command, error: saved ? nil : localized("Recording cancelled", "录屏已取消"))
        self.close()
      }
      controller.show()
      return
    }
    if tool == .longCapture {
      guard !command.copy, !command.raw, command.path == nil, !command.pin, !command.geometry else { return }
      if !canvas.document.annotations.isEmpty, Environment.shared.preferences.bool("showQuitPrompt") {
        hide()
        if !confirmDiscard() { show(); return }
      }
      let selection = canvas.document.selection!
      let source = canvas.sourceApplication(at: CGPoint(x: selection.midX, y: selection.midY))
      hide()
      let controller = LongCaptureSession(screen: active.screen, selection: selection, source: source)
      longCapture = controller
      controller.onFinish = { [weak self] result in
        guard let self else { return }
        self.longCapture = nil
        switch result {
        case .cancel: self.close(cancelled: true); return
        case .copy(let image): self.app?.respond(self.command, image: image)
        case .save(let image, let url):
          self.app?.notifySaved(url)
          self.app?.respond(self.command, image: image)
        case .pin(let image):
          self.app?.pin(image, screen: self.active.screen)
          self.app?.respond(self.command, image: image)
        case .text(let image):
          self.app?.recognize(image, kind: .text)
          self.app?.respond(self.command, image: image)
        }
        self.close()
      }
      controller.show()
      return
    }
    do {
      let image = try canvas.rendered()
      let selection = canvas.document.pixelSelection
      switch tool {
      case .recognizeText, .recognizeQRCode:
        guard !command.copy, !command.raw, command.path == nil, !command.pin, !command.geometry else {
          return
        }
        hide()
        app?.recognize(image, kind: tool == .recognizeText ? .text : .qrCode)
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
      recordCapture(canvas)
      app?.respond(command, image: image, selection: selection)
      close()
    } catch {
      hide()
      warning(localized("Capture failed", "截图操作失败"), errorMessage(error))
      show()
    }
  }
}
