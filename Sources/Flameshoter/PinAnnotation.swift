// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

@MainActor final class PinAnnotationController: NSWindowController, NSWindowDelegate {
  let pin: PinWindowController
  let canvas: CanvasView
  private let toolbar: CaptureToolbar
  private weak var app: AppController?
  private var accepted = false
  private var busy = false
  private var task: Task<Void, Never>?
  var onClose: ((PinAnnotationController) -> Void)?

  init(pin: PinWindowController, app: AppController) {
    self.pin = pin
    self.app = app
    let screen = pin.window?.screen ?? NSScreen.main!
    let image = pin.displayedImage
    let available = screen.visibleFrame.size
    // Keep controls in a separate viewport, even when the source is a tiny image or banner.
    let viewportSize = CGSize(
      width: min(
        available.width * 0.9, max(760, CGFloat(image.width) / screen.backingScaleFactor + 80)),
      height: min(
        available.height * 0.85, max(500, CGFloat(image.height) / screen.backingScaleFactor + 100)))
    let fit = min(
      max(
        1 / screen.backingScaleFactor, min(480 / CGFloat(image.width), 320 / CGFloat(image.height))),
      (viewportSize.width - 80) / CGFloat(image.width),
      (viewportSize.height - 100) / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
    let frame = CapturedScreen(image: image, screen: screen, imageLogicalSize: size)
    canvas = CanvasView(frame: frame)
    canvas.setSelection(CGRect(origin: .zero, size: size))
    let viewport = FlippedView(frame: CGRect(origin: .zero, size: viewportSize))
    viewport.wantsLayer = true
    viewport.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    canvas.setFrameOrigin(
      CGPoint(
        x: (viewportSize.width - size.width) / 2, y: (viewportSize.height - size.height) / 2))
    viewport.addSubview(canvas)
    let tools = Set(
      Tool.allCases.filter(\.isDrawing) + [
        .select, .moveSelection, .undo, .redo,
        .autoRedact, .recognizeText, .recognizeQRCode, .translate, .recognizeDocument,
        .recognizeTable,
        .copy, .save, .accept, .exit,
      ])
    toolbar = CaptureToolbar(canvas: canvas, availableTools: tools, hostView: viewport)
    let window = CaptureWindow(
      contentRect: CGRect(origin: .zero, size: viewportSize),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = localized("Annotate pinned image · Return to pin", "标注贴图 · 回车置顶结果")
    window.contentView = viewport
    window.canvas = canvas
    window.captureToolbar = toolbar
    window.acceptsMouseMovedEvents = true
    window.center()
    super.init(window: window)
    window.delegate = self
    canvas.onChange = { [weak self] in self?.toolbar.refresh() }
    canvas.onInspector = { [weak self] in self?.toolbar.toggleInspector() }
    canvas.onAction = { [weak self] tool in self?.perform(tool) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  func show() {
    pin.window?.orderOut(nil)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(canvas)
    NSApp.activate()
  }
  private func perform(_ tool: Tool) {
    guard !busy else { return }
    if tool == .exit {
      close()
      return
    }
    busy = true
    task = Task { [weak self] in
      guard let self else { return }
      defer { self.busy = false }
      do {
        let image = try self.canvas.rendered()
        switch tool {
        case .accept, .pin:
          self.accepted = true
          self.app?.pin(image, screen: self.pin.window?.screen)
          self.pin.close()
          self.close()
        case .copy: try await ImageRenderer.copy(image)
        case .save: _ = try await Files.save(image, forceDialog: true)
        case .recognizeText: self.app?.recognize(image, kind: .text)
        case .recognizeQRCode: self.app?.recognize(image, kind: .qrCode)
        case .recognizeDocument: self.app?.recognize(image, kind: .document)
        case .translate: self.app?.translate(image)
        case .recognizeTable: self.app?.recognizeTable(image)
        case .autoRedact:
          guard let options = AutoRedaction.chooseOptions() else { return }
          let annotations = self.canvas.document.annotations
          let selection = self.canvas.document.selection
          let pixel = self.canvas.document.pixelSelection
          let scale = self.canvas.document.scale
          let regions = try await AutoRedaction.regions(image, options: options)
          guard !Task.isCancelled, self.canvas.document.selection == selection,
            self.canvas.document.annotations == annotations
          else { return }
          self.canvas.setAnnotations(
            annotations
              + AutoRedaction.annotations(
                regions: regions,
                selection: CGRect(
                  x: pixel.minX / scale, y: pixel.minY / scale,
                  width: pixel.width / scale, height: pixel.height / scale), scale: scale),
            name: toolTitle(.autoRedact))
        default: break
        }
      } catch {
        if !Task.isCancelled {
          warning(
            localized("Unable to edit pinned image", "无法编辑贴图"), errorMessage(error),
            window: self.window)
        }
      }
    }
  }
  func windowWillClose(_ notification: Notification) {
    task?.cancel()
    toolbar.close()
    if !accepted { pin.show() }
    onClose?(self)
  }
}
