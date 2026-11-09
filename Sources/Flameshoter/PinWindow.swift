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
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  override func scrollWheel(with event: NSEvent) {
    guard let window else { return }
    if event.modifierFlags.contains(.command) {
      window.alphaValue = min(
        1, max(0.15, window.alphaValue + (event.scrollingDeltaY > 0 ? 0.05 : -0.05)))
      return
    }
    controller?.zoom(event.scrollingDeltaY > 0 ? 1.03 : 1 / 1.03)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53
      || Environment.shared.preferences.shortcut("TYPE_CLOSE_ACTIVE_PIN_WINDOW")?.matches(event)
        == true
    {
      window?.close()
      return
    }
    if Environment.shared.preferences.shortcut(Tool.recognizeText.legacyName)?.matches(event) == true {
      controller?.recognizeText(nil)
      return
    }
    if Environment.shared.preferences.shortcut(Tool.recognizeQRCode.legacyName)?.matches(event) == true {
      controller?.recognizeQRCode(nil)
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
      (localized("Open with…", "使用其他应用打开…"), #selector(PinWindowController.openImage(_:))),
      (localized("Recognize text…", "识别文字…"), #selector(PinWindowController.recognizeText(_:))),
      (localized("Recognize QR code…", "识别二维码…"), #selector(PinWindowController.recognizeQRCode(_:))),
      (localized("Actual size", "实际大小"), #selector(PinWindowController.actualSize(_:))),
      (localized("Close", "关闭"), #selector(PinWindowController.closeImage(_:))),
    ] {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
      item.target = controller
      menu.addItem(item)
    }
  }
}
@MainActor final class PinWindowController: NSWindowController, NSWindowDelegate,
  ImageAnalysisOverlayViewDelegate
{
  let image: CGImage
  let imageView = PinImageView()
  var onClose: ((PinWindowController) -> Void)?
  var onRecognize: ((CGImage, RecognitionKind) -> Void)?
  private let textOverlay = ImageAnalysisOverlayView()
  private var analysisStarted = false
  private var analysisTask: Task<Void, Never>?
  private let naturalSize: CGSize
  init(image: CGImage, screen: NSScreen? = NSScreen.main) {
    self.image = image
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
    NSApp.activate()
    if !analysisStarted {
      analysisStarted = true
      analysisTask = Task { [weak self] in
        guard let self else { return }
        let analysis = try? await ImageRecognition.text(self.image)
        if !Task.isCancelled { self.textOverlay.analysis = analysis }
      }
    }
  }
  func zoom(_ factor: CGFloat) {
    guard let window else { return }
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
          image, jpeg: Environment.shared.preferences.bool("useJpgForClipboard"),
          quality: Environment.shared.preferences.integer("jpegQuality"),
          optimize: Environment.shared.preferences.bool("losslessCompression"))
      } catch { warning(localized("Copy failed", "复制失败"), errorMessage(error), window: window) }
    }
  }
  @objc func saveImage(_ sender: Any?) {
    Task {
      do { _ = try await Files.save(image, forceDialog: true) } catch {
        warning(localized("Save failed", "保存失败"), errorMessage(error), window: window)
      }
    }
  }
  @objc func openImage(_ sender: Any?) {
    Task {
      do { _ = try await Files.openWith(image) } catch {
        warning(localized("Open failed", "打开失败"), errorMessage(error), window: window)
      }
    }
  }
  @objc func actualSize(_ sender: Any?) { window?.setContentSize(naturalSize) }
  @objc func recognizeText(_ sender: Any?) { onRecognize?(image, .text) }
  @objc func recognizeQRCode(_ sender: Any?) { onRecognize?(image, .qrCode) }
  @objc func closeImage(_ sender: Any?) { window?.close() }
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
