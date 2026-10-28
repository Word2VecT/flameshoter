// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

@MainActor final class PinImageView: NSImageView {
  weak var controller: PinWindowController?
  override var acceptsFirstResponder: Bool { true }
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
    for (title, selector) in [
      (localized("Copy", "复制"), #selector(PinWindowController.copyImage(_:))),
      (localized("Save…", "保存…"), #selector(PinWindowController.saveImage(_:))),
      (localized("Open with…", "使用其他应用打开…"), #selector(PinWindowController.openImage(_:))),
      (localized("Actual size", "实际大小"), #selector(PinWindowController.actualSize(_:))),
      (localized("Close", "关闭"), #selector(PinWindowController.closeImage(_:))),
    ] {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
      item.target = controller
      menu.addItem(item)
    }
    return menu
  }
}
@MainActor final class PinWindowController: NSWindowController, NSWindowDelegate {
  let image: CGImage
  let imageView = PinImageView()
  var onClose: ((PinWindowController) -> Void)?
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
    window.isMovableByWindowBackground = true
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
  @objc func closeImage(_ sender: Any?) { window?.close() }
  func windowWillClose(_ notification: Notification) { onClose?(self) }
}
