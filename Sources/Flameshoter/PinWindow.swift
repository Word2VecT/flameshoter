// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import VisionKit

@MainActor final class PinImageView: NSImageView {
  weak var controller: PinWindowController?
  weak var textOverlay: ImageAnalysisOverlayView?
  override var acceptsFirstResponder: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    guard let textOverlay else { return hit }
    let location = textOverlay.convert(point, from: superview)
    // VisionKit's image hit tests use top-left coordinates; AppKit image views are unflipped.
    let imagePoint = CGPoint(
      x: location.x, y: textOverlay.isFlipped ? location.y : textOverlay.bounds.height - location.y)
    if textOverlay.analysisHasText(at: imagePoint) || textOverlay.hasText(at: imagePoint)
      || textOverlay.hasActiveTextSelection
      || textOverlay.hasSupplementaryInterface(at: imagePoint)
    {
      return hit
    }
    return self
  }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.close()
      return
    }
    if controller?.locked != true { window?.performDrag(with: event) }
  }
  override func scrollWheel(with event: NSEvent) {
    guard let window else { return }
    guard controller?.locked != true else { return }
    if event.modifierFlags.contains(.command) {
      window.alphaValue = min(
        1, max(0.15, window.alphaValue + (event.scrollingDeltaY > 0 ? 0.05 : -0.05)))
      if let controller { controller.onChange?(controller) }
      return
    }
    controller?.zoom(event.scrollingDeltaY > 0 ? 1.03 : 1 / 1.03)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 37, event.modifierFlags.intersection(Shortcut.relevant).isEmpty {
      controller?.toggleLock(nil)
      return
    }
    if event.keyCode == 49, event.modifierFlags.intersection(Shortcut.relevant).isEmpty {
      controller?.annotate(nil)
      return
    }
    if event.keyCode == 53
      || Environment.shared.preferences.shortcut("TYPE_CLOSE_ACTIVE_PIN_WINDOW")?.matches(event)
        == true
    {
      window?.close()
      return
    }
    if Environment.shared.preferences.shortcut(Tool.recognizeText.legacyName)?.matches(event)
      == true
    {
      controller?.recognizeText(nil)
      return
    }
    if Environment.shared.preferences.shortcut(Tool.recognizeQRCode.legacyName)?.matches(event)
      == true
    {
      controller?.recognizeQRCode(nil)
      return
    }
    if Environment.shared.preferences.shortcut(Tool.translate.legacyName)?.matches(event) == true {
      controller?.translateImage(nil)
      return
    }
    if Environment.shared.preferences.shortcut(Tool.recognizeTable.legacyName)?.matches(event)
      == true
    {
      controller?.recognizeTable(nil)
      return
    }
    if Environment.shared.preferences.shortcut(Tool.recognizeDocument.legacyName)?.matches(event)
      == true
    {
      controller?.recognizeDocument(nil)
      return
    }
    if event.modifierFlags.contains(.command), event.keyCode == 8 {
      controller?.copyImage(nil)
      return
    }
    if event.modifierFlags.contains(.command), event.keyCode == 1 {
      controller?.saveImage(nil)
      return
    }
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    appendActions(to: menu)
    return menu
  }
  func appendActions(to menu: NSMenu) {
    for (title, selector) in [
      (localized("Copy", "复制"), #selector(PinWindowController.copyImage(_:))),
      (localized("Save…", "保存…"), #selector(PinWindowController.saveImage(_:))),
      (localized("Annotate…", "标注…"), #selector(PinWindowController.annotate(_:))),
      (localized("Rotate clockwise", "顺时针旋转"), #selector(PinWindowController.rotateClockwise(_:))),
      (localized("Flip horizontally", "水平翻转"), #selector(PinWindowController.flipHorizontally(_:))),
      (
        controller?.locked == true ? localized("Unlock", "解锁") : localized("Lock", "锁定"),
        #selector(PinWindowController.toggleLock(_:))
      ),
      (localized("Open with…", "使用其他应用打开…"), #selector(PinWindowController.openImage(_:))),
      (localized("Recognize text…", "识别文字…"), #selector(PinWindowController.recognizeText(_:))),
      (
        localized("Recognize QR / barcode…", "识别二维码 / 条码…"),
        #selector(PinWindowController.recognizeQRCode(_:))
      ),
      (localized("Translate…", "翻译…"), #selector(PinWindowController.translateImage(_:))),
      (localized("Recognize table…", "识别表格…"), #selector(PinWindowController.recognizeTable(_:))),
      (
        localized("Recognize document…", "识别文档…"),
        #selector(PinWindowController.recognizeDocument(_:))
      ),
      (localized("Actual size", "实际大小"), #selector(PinWindowController.actualSize(_:))),
      (localized("Close", "关闭"), #selector(PinWindowController.closeImage(_:))),
    ] {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
      item.target = controller
      menu.addItem(item)
    }
  }
}
@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate,
  ImageAnalysisOverlayViewDelegate
{
  let image: CGImage
  private(set) var displayedImage: CGImage
  private(set) var quarterTurns = 0
  private(set) var mirrored = false
  private(set) var locked = false
  let archiveID: UUID
  let created: Date
  var closed: Date?
  let imageView = PinImageView()
  var onClose: ((PinWindowController) -> Void)?
  var onChange: ((PinWindowController) -> Void)?
  var onRecognize: ((CGImage, RecognitionKind) -> Void)?
  var onTranslate: ((CGImage) -> Void)?
  var onRecognizeTable: ((CGImage) -> Void)?
  var onAnnotate: ((PinWindowController) -> Void)?
  private let textOverlay = ImageAnalysisOverlayView()
  private var analysisStarted = false
  private var analysisTask: Task<Void, Never>?
  private var naturalSize: CGSize
  init(image: CGImage, screen: NSScreen? = NSScreen.main, id: UUID = UUID(), created: Date = Date())
  {
    self.image = image
    displayedImage = image
    archiveID = id
    self.created = created
    let scale = screen?.backingScaleFactor ?? 2
    naturalSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: naturalSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = localized("Pinned capture", "置顶截图")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.level = .floating
    window.hasShadow = true
    window.isReleasedWhenClosed = false
    window.contentAspectRatio = naturalSize
    window.contentMinSize = NSSize(
      width: 80, height: 80 * naturalSize.height / max(1, naturalSize.width))
    super.init(window: window)
    window.delegate = self
    imageView.controller = self
    imageView.image = NSImage(cgImage: image, size: naturalSize)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.magnificationFilter =
      Environment.shared.preferences.bool("antialiasingPinZoom") ? .linear : .nearest
    textOverlay.frame = imageView.bounds
    textOverlay.autoresizingMask = [.width, .height]
    textOverlay.trackingImageView = imageView
    textOverlay.preferredInteractionTypes = .textSelection
    textOverlay.delegate = self
    imageView.textOverlay = textOverlay
    imageView.addSubview(textOverlay)
    window.contentView = imageView
    window.center()
    if let visible = screen?.visibleFrame,
      window.frame.width > visible.width * 0.8 || window.frame.height > visible.height * 0.8
    {
      zoom(
        min(visible.width * 0.8 / window.frame.width, visible.height * 0.8 / window.frame.height))
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(imageView)
    NSApp.activate()
    if !analysisStarted {
      analysisStarted = true
      analysisTask = Task { [weak self] in
        guard let self else { return }
        let analysis = try? await ImageRecognition.text(self.displayedImage)
        if !Task.isCancelled { self.textOverlay.analysis = analysis }
      }
    }
  }
  func zoom(_ factor: CGFloat) {
    guard let window, !locked else { return }
    let old = window.frame
    let size = NSSize(width: max(80, old.width * factor), height: max(80, old.height * factor))
    window.setFrame(
      NSRect(
        x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width,
        height: size.height), display: true)
  }
  @objc func copyImage(_ sender: Any?) {
    if !textOverlay.selectedText.isEmpty {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(textOverlay.selectedText, forType: .string)
      return
    }
    Task {
      do {
        try await ImageRenderer.copy(
          displayedImage, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
          quality: Environment.shared.preferences.integer("jpegQuality"),
          optimize: Environment.shared.preferences.bool("losslessCompression"))
      } catch { warning(localized("Copy failed", "复制失败"), errorMessage(error), window: window) }
    }
  }
  @objc func saveImage(_ sender: Any?) {
    Task {
      do { _ = try await Files.save(displayedImage, forceDialog: true) } catch {
        warning(localized("Save failed", "保存失败"), errorMessage(error), window: window)
      }
    }
  }
  @objc func openImage(_ sender: Any?) {
    Task {
      do { _ = try await Files.openWith(displayedImage) } catch {
        warning(localized("Open failed", "打开失败"), errorMessage(error), window: window)
      }
    }
  }
  @objc func actualSize(_ sender: Any?) { if !locked { window?.setContentSize(naturalSize) } }
  @objc func recognizeText(_ sender: Any?) { onRecognize?(displayedImage, .text) }
  @objc func recognizeQRCode(_ sender: Any?) { onRecognize?(displayedImage, .qrCode) }
  @objc func recognizeDocument(_ sender: Any?) { onRecognize?(displayedImage, .document) }
  @objc func translateImage(_ sender: Any?) { onTranslate?(displayedImage) }
  @objc func recognizeTable(_ sender: Any?) { onRecognizeTable?(displayedImage) }
  @objc func annotate(_ sender: Any?) { onAnnotate?(self) }
  @objc func rotateClockwise(_ sender: Any?) {
    guard !locked else { return }
    quarterTurns = (quarterTurns + 1) % 4
    updateTransform()
  }
  @objc func flipHorizontally(_ sender: Any?) {
    guard !locked else { return }
    mirrored.toggle()
    updateTransform()
  }
  @objc func toggleLock(_ sender: Any?) {
    locked.toggle()
    if locked { window?.styleMask.remove(.resizable) } else { window?.styleMask.insert(.resizable) }
    onChange?(self)
  }
  func restoreTransform(from record: ArchivedPin) {
    quarterTurns = ((record.quarterTurns ?? 0) % 4 + 4) % 4
    mirrored = record.mirrored ?? false
    updateTransform(notify: false)
    if record.locked == true { toggleLock(nil) }
  }
  private func updateTransform(notify: Bool = true) {
    do {
      displayedImage = try PinImageTransform.apply(
        image, quarterTurns: quarterTurns, mirrored: mirrored)
      let scale = window?.screen?.backingScaleFactor ?? 2
      naturalSize = CGSize(
        width: CGFloat(displayedImage.width) / scale, height: CGFloat(displayedImage.height) / scale
      )
      imageView.image = NSImage(cgImage: displayedImage, size: naturalSize)
      window?.contentAspectRatio = naturalSize
      window?.contentMinSize = NSSize(
        width: 80, height: 80 * naturalSize.height / max(1, naturalSize.width))
      if let window {
        let current = window.contentView?.frame.size ?? naturalSize
        var proposed = NSSize(
          width: current.width, height: current.width * naturalSize.height / naturalSize.width)
        if let visible = window.screen?.visibleFrame {
          let fit = min(
            1, visible.width * 0.8 / proposed.width, visible.height * 0.8 / proposed.height)
          proposed = NSSize(width: proposed.width * fit, height: proposed.height * fit)
        }
        window.setContentSize(proposed)
      }
      textOverlay.analysis = nil
      analysisTask?.cancel()
      analysisStarted = false
      if window?.isVisible == true { show() }
      if notify { onChange?(self) }
    } catch {
      warning(localized("Unable to transform image", "无法变换图片"), errorMessage(error), window: window)
    }
  }
  @objc func closeImage(_ sender: Any?) { window?.close() }
  func windowDidMove(_ notification: Notification) { onChange?(self) }
  func windowDidResize(_ notification: Notification) { onChange?(self) }
  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
    forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
  ) -> Bool {
    let reflected = CGPoint(x: point.x, y: overlayView.bounds.height - point.y)
    return overlayView.analysisHasText(at: point) || overlayView.analysisHasText(at: reflected)
      || overlayView.hasInteractiveItem(at: point) || overlayView.hasActiveTextSelection
  }
  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent,
    at point: CGPoint
  ) -> NSMenu {
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    imageView.appendActions(to: menu)
    return menu
  }
  func windowWillClose(_ notification: Notification) {
    analysisTask?.cancel()
    analysisTask = nil
    textOverlay.analysis = nil
    analysisStarted = false
    onClose?(self)
  }
}
