// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ScreenCaptureKit

@MainActor private final class LongCapturePanel: NSPanel {
  var onKey: ((NSEvent) -> Bool)?
  override var canBecomeKey: Bool { true }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if onKey?(event) == true { return true }
    return super.performKeyEquivalent(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if onKey?(event) != true { super.keyDown(with: event) }
  }
}

private struct LongCaptureSnapshot {
  let direction: LongCaptureDirection
  let segments: [LongCaptureSegment]
  let lowerBound: Int
  let length: Int
  let crossLength: Int
  let frameLength: Int
  let position: Int
}

private actor LongCaptureWorker {
  private var capture: LongCapture?
  let direction: LongCaptureDirection
  private var autoTrim: Bool
  init(direction: LongCaptureDirection, autoTrim: Bool) {
    self.direction = direction
    self.autoTrim = autoTrim
  }
  func append(_ image: CGImage) throws -> (LongCaptureUpdate, LongCaptureSnapshot) {
    let update: LongCaptureUpdate
    if let capture {
      update = try capture.append(image)
    } else {
      capture = LongCapture(image: image, direction: direction, autoTrimOnReverse: autoTrim)
      update = .unchanged
    }
    return (update, snapshot()!)
  }
  private func snapshot() -> LongCaptureSnapshot? {
    guard let capture else { return nil }
    return LongCaptureSnapshot(
      direction: direction, segments: capture.segments, lowerBound: capture.lowerBound,
      length: capture.length, crossLength: capture.crossLength, frameLength: capture.frameLength,
      position: capture.position)
  }
  func trim(before: Bool) throws -> LongCaptureSnapshot? {
    guard let capture else { return nil }
    if before { try capture.trimBeforeCurrent() } else { try capture.trimAfterCurrent() }
    return snapshot()
  }
  func image() throws -> CGImage? { try capture?.image() }
  func setAutoTrim(_ enabled: Bool) {
    autoTrim = enabled
    capture?.autoTrimOnReverse = enabled
  }
}

@MainActor private final class LongCapturePreview: NSView {
  var snapshot: LongCaptureSnapshot? {
    didSet {
      updateFrame()
      needsDisplay = true
    }
  }
  override var isFlipped: Bool { true }
  private func updateFrame() {
    guard let snapshot else { return }
    let factor: CGFloat =
      snapshot.direction == .vertical
      ? 280 / CGFloat(snapshot.crossLength) : 180 / CGFloat(snapshot.crossLength)
    let width = snapshot.direction == .vertical ? 280 : CGFloat(snapshot.length) * factor
    let height = snapshot.direction == .vertical ? CGFloat(snapshot.length) * factor : 180
    frame.size = CGSize(width: width, height: height)
  }
  func followCurrentFrame() {
    guard let snapshot, let scrollView = enclosingScrollView else { return }
    let factor: CGFloat =
      snapshot.direction == .vertical
      ? bounds.width / CGFloat(snapshot.crossLength) : bounds.height / CGFloat(snapshot.crossLength)
    let offset = CGFloat(snapshot.position - snapshot.lowerBound) * factor
    let visible = scrollView.contentView.documentVisibleRect
    let origin =
      snapshot.direction == .vertical
      ? CGPoint(
        x: visible.minX,
        y: max(
          0,
          min(
            bounds.height - visible.height,
            offset + CGFloat(snapshot.frameLength) * factor / 2 - visible.height / 2)))
      : CGPoint(
        x: max(
          0,
          min(
            bounds.width - visible.width,
            offset + CGFloat(snapshot.frameLength) * factor / 2 - visible.width / 2)),
        y: visible.minY)
    scrollView.contentView.scroll(to: origin)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let snapshot else { return }
    NSGraphicsContext.current?.imageInterpolation = .low
    let factor: CGFloat =
      snapshot.direction == .vertical
      ? bounds.width / CGFloat(snapshot.crossLength) : bounds.height / CGFloat(snapshot.crossLength)
    for segment in snapshot.segments {
      let offset = CGFloat(segment.position - snapshot.lowerBound) * factor
      let rect =
        snapshot.direction == .vertical
        ? CGRect(
          x: 0, y: offset, width: bounds.width, height: CGFloat(segment.image.height) * factor)
        : CGRect(
          x: offset, y: 0, width: CGFloat(segment.image.width) * factor, height: bounds.height)
      guard rect.intersects(dirtyRect) else { continue }
      NSImage(cgImage: segment.image, size: rect.size).draw(
        in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
      )
    }
    let offset = CGFloat(snapshot.position - snapshot.lowerBound) * factor
    let current =
      snapshot.direction == .vertical
      ? CGRect(x: 0, y: offset, width: bounds.width, height: CGFloat(snapshot.frameLength) * factor)
      : CGRect(
        x: offset, y: 0, width: CGFloat(snapshot.frameLength) * factor, height: bounds.height)
    NSColor.controlAccentColor.setStroke()
    let outline = NSBezierPath(rect: current.insetBy(dx: 1, dy: 1))
    outline.lineWidth = 2
    outline.stroke()
  }
}

@MainActor final class LongCaptureSession: NSObject, NSWindowDelegate {
  enum Output {
    case copy(CGImage)
    case save(CGImage, URL)
    case pin(CGImage)
    case text(CGImage)
    case cancel
  }
  var onFinish: ((Output) -> Void)?
  private let screen: NSScreen
  private let selection: CGRect
  private let source: NSRunningApplication?
  private let screenSelection: CGRect
  private let panel: LongCapturePanel
  private let preview = LongCapturePreview()
  private let scroll = NSScrollView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private var directionControl: ActionPopup!
  private var autoButton: ActionButton!
  private var worker = LongCaptureWorker(
    direction: .vertical, autoTrim: Environment.shared.preferences.bool("longCaptureAutoTrim"))
  private var direction: LongCaptureDirection = .vertical
  private var latest: LongCaptureSnapshot?
  private var captureTask: Task<Void, Never>?
  private var autoTask: Task<Void, Never>?
  private var busy = false
  private var closed = false
  private var needsEventPermission = false

  init(screen: NSScreen, selection: CGRect, source: NSRunningApplication?) {
    self.screen = screen
    self.selection = selection
    self.source = source
    screenSelection = CGRect(
      x: screen.frame.minX + selection.minX, y: screen.frame.maxY - selection.maxY,
      width: selection.width, height: selection.height)
    panel = LongCapturePanel(
      contentRect: CGRect(x: 0, y: 0, width: 340, height: 495),
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()
    panel.title = localized("Scrolling capture", "长截图")
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
    panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    directionControl = ActionPopup(
      items: [localized("Vertical", "纵向"), localized("Horizontal", "横向")], selected: 0
    ) { [weak self] index in self?.changeDirection(index) }
    autoButton = ActionButton(localized("Auto scroll", "自动滚动")) { [weak self] in
      self?.toggleAutomatic()
    }
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    scroll.drawsBackground = true
    scroll.documentView = preview
    scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
    scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    status.textColor = .secondaryLabelColor
    status.stringValue = localized(
      "Scroll slowly inside the selected area. Exclude fixed headers and scrollbars.",
      "在选区内缓慢滚动，避免选入固定标题栏和滚动条。")
    let buttons = stack(
      [
        ActionButton(localized("Copy", "复制")) { [weak self] in self?.output(.copy) },
        ActionButton(localized("Save…", "保存…")) { [weak self] in self?.output(.save) },
        ActionButton(localized("Pin", "置顶")) { [weak self] in self?.output(.pin) },
        ActionButton(localized("Text", "识别文字")) { [weak self] in self?.output(.text) },
        ActionButton(localized("Cancel", "取消")) { [weak self] in self?.finish(.cancel) },
      ], vertical: false, spacing: 8)
    let cropButtons = stack(
      [
        ActionButton(localized("Crop beginning", "裁剪开头")) { [weak self] in self?.trim(before: true)
        },
        ActionButton(localized("Crop end", "裁剪末尾")) { [weak self] in self?.trim(before: false) },
        NSView(),
      ], vertical: false, spacing: 8)
    let autoTrim = ActionCheck(
      localized("Crop automatically when reversing", "反向滚动时自动裁剪"),
      on: Environment.shared.preferences.bool("longCaptureAutoTrim")
    ) { [weak self] enabled in
      Environment.shared.settings.set("longCaptureAutoTrim", enabled)
      if let worker = self?.worker { Task { await worker.setAutoTrim(enabled) } }
    }
    panel.contentView = padded(
      stack(
        [
          stack(
            [label(localized("Direction", "方向")), directionControl, NSView(), autoButton],
            vertical: false),
          scroll, status, cropButtons, autoTrim, buttons,
        ], spacing: 10), inset: 14)
    let visible = screen.visibleFrame
    let x =
      screenSelection.maxX + 12 + panel.frame.width <= visible.maxX
      ? screenSelection.maxX + 12 : screenSelection.minX - panel.frame.width - 12
    panel.setFrameOrigin(
      CGPoint(
        x: max(visible.minX, min(visible.maxX - panel.frame.width, x)),
        y: max(
          visible.minY,
          min(visible.maxY - panel.frame.height, screenSelection.maxY - panel.frame.height))))
  }

  func show() {
    panel.orderFrontRegardless()
    source?.activate()
    startPolling()
  }

  private func changeDirection(_ index: Int) {
    let proposed: LongCaptureDirection = index == 0 ? .vertical : .horizontal
    guard proposed != direction else { return }
    if let latest, latest.length > latest.frameLength {
      let alert = NSAlert()
      alert.messageText = localized("Restart scrolling capture?", "重新开始长截图？")
      alert.informativeText = localized(
        "Changing direction clears the current result.", "更改方向会清除当前拼接结果。")
      alert.addButton(withTitle: localized("Cancel", "取消"))
      alert.addButton(withTitle: localized("Restart", "重新开始"))
      guard alert.runModal() == .alertSecondButtonReturn else {
        directionControl.selectItem(at: direction == .vertical ? 0 : 1)
        return
      }
    }
    captureTask?.cancel()
    stopAutomatic()
    direction = proposed
    worker = LongCaptureWorker(
      direction: direction, autoTrim: Environment.shared.preferences.bool("longCaptureAutoTrim"))
    latest = nil
    preview.snapshot = nil
    source?.activate()
    startPolling()
  }

  private func startPolling() {
    guard !closed else { return }
    let worker = self.worker
    captureTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard let source = self.source else {
          self.status.stringValue = localized(
            "No source window found. Cancel and select a window to capture.",
            "未找到来源窗口，请取消后重新选择应用窗口。")
          return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: true)
        guard
          let number = self.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber,
          let display = content.displays.first(where: { $0.displayID == number.uint32Value })
        else { throw CaptureError.display }
        let ownApps = content.applications.filter {
          $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
          display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCScreenshotConfiguration()
        configuration.sourceRect = self.selection
        configuration.width = max(
          1, Int((self.selection.width * self.screen.backingScaleFactor).rounded()))
        configuration.height = max(
          1, Int((self.selection.height * self.screen.backingScaleFactor).rounded()))
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.displayIntent = .local
        try await Task.sleep(for: .milliseconds(180))
        while !Task.isCancelled {
          let displayFrame = AutoSelection.displayFrame(
            self.screen.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
          let selectedWindow = AutoSelection.window(
            at: CGPoint(x: self.selection.midX, y: self.selection.midY),
            in: AutoSelection.windows(on: displayFrame))
          if !source.isActive || selectedWindow?.processID != source.processIdentifier {
            self.stopAutomatic()
            self.status.stringValue = localized(
              "Return to the selected window to continue capture.", "请切回所选窗口以继续截图。")
            try await Task.sleep(for: .milliseconds(400))
            continue
          }
          let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: configuration)
          guard let image = output.sdrImage else { throw ImageError.renderFailed }
          let (result, snapshot) = try await worker.append(image)
          guard !Task.isCancelled else { return }
          if self.latest == nil || result == .moved || result == .extended {
            self.preview.snapshot = snapshot
            if result == .moved || result == .extended { self.preview.followCurrentFrame() }
          }
          self.latest = snapshot
          if result == .mismatch {
            self.stopAutomatic()
            self.status.stringValue = localized(
              "Cannot match this frame. Scroll back to the last matched position and try again.",
              "画面无法匹配，请滚回上一次成功的位置后继续。")
          } else if self.needsEventPermission {
            self.status.stringValue = localized(
              "Auto scroll needs Accessibility access. Allow Flameshoter in System Settings.",
              "自动滚动需要辅助功能权限，请在系统设置中允许 Flameshoter。")
          } else if self.autoTask != nil && !self.screenSelection.contains(NSEvent.mouseLocation) {
            self.status.stringValue = localized(
              "Move the pointer into the selected area to auto scroll.", "将鼠标移入选区即可自动滚动。")
          } else {
            self.status.stringValue =
              localized("Scroll slowly · ", "缓慢滚动 · ")
              + (snapshot.direction == .vertical
                ? "\(snapshot.crossLength) × \(snapshot.length)"
                : "\(snapshot.length) × \(snapshot.crossLength)")
          }
          try await Task.sleep(for: .milliseconds(400))
        }
      } catch {
        guard !Task.isCancelled else { return }
        self.status.stringValue = localized("Capture failed: ", "截取失败：") + errorMessage(error)
      }
    }
  }

  private func toggleAutomatic() {
    if autoTask != nil {
      stopAutomatic()
      return
    }
    guard source != nil else {
      status.stringValue = localized(
        "Auto scroll requires a target application window.", "自动滚动需要选中应用窗口。")
      return
    }
    guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
      needsEventPermission = true
      status.stringValue = localized(
        "Auto scroll needs Accessibility access. Allow Flameshoter in System Settings.",
        "自动滚动需要辅助功能权限，请在系统设置中允许 Flameshoter。")
      return
    }
    needsEventPermission = false
    autoButton.title = localized("Stop scrolling", "停止滚动")
    source?.activate()
    autoTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let mouse = NSEvent.mouseLocation
        if let event = AutoScroll.event(
          mouse: mouse, selection: self.screenSelection,
          sourceIsActive: self.source?.isActive == true,
          direction: self.direction, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        {
          event.post(tap: .cghidEventTap)
        }
        do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
      }
    }
  }
  private func stopAutomatic() {
    autoTask?.cancel()
    autoTask = nil
    autoButton.title = localized("Auto scroll", "自动滚动")
  }

  private enum Action { case copy, save, pin, text }
  private func handleKey(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(Shortcut.relevant)
    if modifiers.isEmpty {
      switch event.keyCode {
      case 53:
        finish(.cancel)
        return true
      case 0:
        toggleAutomatic()
        return true
      case 38:
        trim(before: true)
        return true
      case 40:
        trim(before: false)
        return true
      default: break
      }
    }
    let preferences = Environment.shared.preferences
    for (name, action) in [
      (Tool.copy.legacyName, Action.copy), (Tool.save.legacyName, .save),
      (Tool.pin.legacyName, .pin), (Tool.recognizeText.legacyName, .text),
    ] where preferences.shortcut(name)?.matches(event) == true {
      output(action)
      return true
    }
    return false
  }
  private func trim(before: Bool) {
    let worker = self.worker
    Task { [weak self] in
      guard let self else { return }
      do {
        guard let snapshot = try await worker.trim(before: before), worker === self.worker,
          !self.closed
        else { return }
        self.latest = snapshot
        self.preview.snapshot = snapshot
        self.preview.followCurrentFrame()
      } catch { warning(localized("Crop failed", "裁剪失败"), errorMessage(error), window: self.panel) }
    }
  }
  private func output(_ action: Action) {
    guard !busy, latest != nil else { return }
    busy = true
    captureTask?.cancel()
    stopAutomatic()
    let worker = self.worker
    Task { [weak self] in
      guard let self else { return }
      defer { self.busy = false }
      do {
        guard let image = try await worker.image() else {
          self.startPolling()
          return
        }
        switch action {
        case .copy:
          try await ImageRenderer.copy(
            image, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
            quality: Environment.shared.preferences.integer("jpegQuality"),
            optimize: Environment.shared.preferences.bool("losslessCompression"))
          if Environment.shared.preferences.bool("saveAfterCopy") {
            _ = try await Files.save(image)
          }
          self.finish(.copy(image))
        case .save:
          guard let url = try await Files.save(image, forceDialog: true) else {
            self.startPolling()
            return
          }
          self.finish(.save(image, url))
        case .pin: self.finish(.pin(image))
        case .text: self.finish(.text(image))
        }
      } catch {
        warning(
          localized("Scrolling capture failed", "长截图操作失败"), errorMessage(error), window: self.panel)
        self.startPolling()
      }
    }
  }

  private func finish(_ output: Output) {
    guard !closed else { return }
    closed = true
    captureTask?.cancel()
    stopAutomatic()
    panel.close()
    onFinish?(output)
  }
  func invalidate() {
    guard !closed else { return }
    closed = true
    captureTask?.cancel()
    stopAutomatic()
    panel.close()
  }
  func windowWillClose(_ notification: Notification) {
    if !closed { finish(.cancel) }
  }
}
