// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ImageIO
import UniformTypeIdentifiers

enum ContentPin {
  case text(NSAttributedString)
  case color(ScreenColor, String)
  case file(URL)
  case animated(Data, UTType)
}

@MainActor final class WebPPlayback {
  private let decoder: AnimatedWebP
  private weak var view: NSImageView?
  private var timer: Timer?
  private var loops = 0
  private var framesThisLoop = 0
  private var running = false
  init(decoder: AnimatedWebP, view: NSImageView) {
    self.decoder = decoder
    self.view = view
  }
  func start() {
    guard !running else { return }
    running = true
    advance()
  }
  func stop() {
    running = false
    timer?.invalidate()
    timer = nil
    decoder.reset()
    loops = 0
    framesThisLoop = 0
  }
  private func advance() {
    guard running, let view else { return }
    if let frame = decoder.nextFrame() {
      framesThisLoop += 1
      view.image = NSImage(
        cgImage: frame.image, size: NSSize(width: decoder.width, height: decoder.height))
      let timer = Timer(timeInterval: frame.duration, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.advance() }
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
      return
    }
    guard framesThisLoop > 0 else {
      running = false
      timer = nil
      return
    }
    loops += 1
    guard decoder.loopCount == 0 || loops < decoder.loopCount else {
      running = false
      timer = nil
      return
    }
    decoder.reset()
    framesThisLoop = 0
    advance()
  }
}

@MainActor private final class AnimatedPinView: NSImageView {
  weak var controller: ContentPinController?
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for (title, action) in [
      (localized("Copy", "复制"), #selector(ContentPinController.copyAnimation(_:))),
      (localized("Save…", "保存…"), #selector(ContentPinController.saveAnimation(_:))),
      (localized("Close", "关闭"), #selector(ContentPinController.closePin(_:))),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = controller
      menu.addItem(item)
    }
    return menu
  }
}

@MainActor final class ContentPinController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  var onClose: ((ContentPinController) -> Void)?
  var onChange: ((ContentPinController, Bool) -> Void)?
  let content: ContentPin
  let archiveID: UUID
  let created: Date
  var closed: Date?
  private var textEditor: NSTextView?
  private var webPPlayback: WebPPlayback?

  init(content: ContentPin, id: UUID = UUID(), created: Date = Date()) {
    self.content = content
    archiveID = id
    self.created = created
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 240),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.minSize = NSSize(width: 220, height: 140)
    super.init(window: window)
    window.delegate = self
    switch content {
    case .text(let text):
      window.title = localized("Pinned text", "置顶文字")
      let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
      editor.isEditable = true
      editor.isRichText = true
      editor.allowsUndo = true
      editor.font = .systemFont(ofSize: 16)
      editor.textContainerInset = NSSize(width: 12, height: 12)
      editor.isVerticallyResizable = true
      editor.textContainer?.widthTracksTextView = true
      editor.textStorage?.setAttributedString(text)
      editor.delegate = self
      textEditor = editor
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.documentView = editor
      window.contentView = scroll
      window.makeFirstResponder(editor)
    case .color(let color, let original):
      window.title = localized("Pinned color", "置顶颜色")
      let swatch = NSView()
      swatch.wantsLayer = true
      swatch.layer?.backgroundColor = color.color.cgColor
      swatch.layer?.cornerRadius = 8
      swatch.heightAnchor.constraint(equalToConstant: 56).isActive = true
      var rows: [NSView] = [swatch, label(original, secondary: true)]
      for format in [ScreenColor.Format.hashHex, .rgb, .hsv, .hsl] {
        let value = color.string(format)
        rows.append(
          ActionButton(value) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
          })
      }
      window.contentView = padded(stack(rows, spacing: 7), inset: 12)
      window.setContentSize(NSSize(width: 310, height: 260))
    case .file(let url):
      window.title = localized("Pinned file", "置顶文件")
      let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
      icon.imageScaling = .scaleProportionallyUpOrDown
      icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
      let name = label(url.lastPathComponent)
      name.lineBreakMode = .byTruncatingMiddle
      let actions = stack(
        [
          ActionButton(localized("Open", "打开")) { NSWorkspace.shared.open(url) },
          ActionButton(localized("Show in Finder", "在访达中显示")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          },
        ], vertical: false, spacing: 8)
      window.contentView = padded(stack([icon, name, actions], spacing: 10), inset: 16)
      window.setContentSize(NSSize(width: 350, height: 190))
    case .animated(let data, let type):
      window.title = localized("Pinned animation", "置顶动图")
      let view = AnimatedPinView()
      view.controller = self
      view.imageScaling = .scaleProportionallyUpOrDown
      window.contentView = view
      let natural: NSSize?
      if type == .webP, let decoder = AnimatedWebP(data: data) {
        webPPlayback = WebPPlayback(decoder: decoder, view: view)
        natural = NSSize(width: decoder.width, height: decoder.height)
      } else {
        view.image = NSImage(data: data)
        view.animates = true
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
          let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
          natural = NSSize(width: first.width, height: first.height)
        } else {
          natural = nil
        }
      }
      if let natural {
        let scale = min(1, 600 / natural.width, 500 / natural.height)
        window.minSize = NSSize(width: 40, height: 40)
        window.contentAspectRatio = natural
        window.setContentSize(NSSize(width: natural.width * scale, height: natural.height * scale))
      }
    }
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    webPPlayback?.start()
  }
  @objc func copyAnimation(_ sender: Any?) {
    guard case .animated(let data, let type) = content else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
  }
  @objc func saveAnimation(_ sender: Any?) {
    guard case .animated(let data, let type) = content else { return }
    let panel = NSSavePanel()
    panel.title = localized("Save animation", "保存动图")
    panel.allowedContentTypes = [type]
    panel.nameFieldStringValue = "Flameshoter." + (type.preferredFilenameExtension ?? "gif")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url, options: .atomic) } catch {
      warning(localized("Save failed", "保存失败"), errorMessage(error), window: window)
    }
  }
  @objc func closePin(_ sender: Any?) { window?.close() }
  func windowDidMove(_ notification: Notification) { onChange?(self, false) }
  func windowDidResize(_ notification: Notification) { onChange?(self, false) }
  func textDidChange(_ notification: Notification) { onChange?(self, true) }
  var archiveKind: ArchivedPin.Kind {
    switch content {
    case .text: return .text
    case .color: return .color
    case .file: return .file
    case .animated(_, let type): return type == .gif ? .gif : .webP
    }
  }
  func archivedPayload() throws -> (ArchivedPin.Kind, Data) {
    switch content {
    case .text(let original):
      let text = textEditor?.textStorage.map { NSAttributedString(attributedString: $0) } ?? original
      let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
      return (.text, data)
    case .color(_, let original): return (.color, Data(original.utf8))
    case .file(let url): return (.file, Data(url.absoluteString.utf8))
    case .animated(let data, let type): return (type == .gif ? .gif : .webP, data)
    }
  }
  func windowWillClose(_ notification: Notification) {
    webPPlayback?.stop()
    onClose?(self)
  }
}
