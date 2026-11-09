// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ContentPin {
  case text(NSAttributedString)
  case color(ScreenColor, String)
  case file(URL)
  case animated(Data)
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

@MainActor final class ContentPinController: NSWindowController, NSWindowDelegate {
  var onClose: ((ContentPinController) -> Void)?
  let content: ContentPin

  init(content: ContentPin) {
    self.content = content
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
    case .animated(let data):
      window.title = localized("Pinned animation", "置顶动图")
      let view = AnimatedPinView()
      view.controller = self
      view.image = NSImage(data: data)
      view.imageScaling = .scaleProportionallyUpOrDown
      view.animates = true
      window.contentView = view
      if let source = CGImageSourceCreateWithData(data as CFData, nil),
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
      {
        let natural = NSSize(width: first.width, height: first.height)
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
  }
  @objc func copyAnimation(_ sender: Any?) {
    guard case .animated(let data) = content else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
  }
  @objc func saveAnimation(_ sender: Any?) {
    guard case .animated(let data) = content else { return }
    let panel = NSSavePanel()
    panel.title = localized("Save animation", "保存动图")
    panel.allowedContentTypes = [.gif]
    panel.nameFieldStringValue = "Flameshoter.gif"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url, options: .atomic) } catch {
      warning(localized("Save failed", "保存失败"), errorMessage(error), window: window)
    }
  }
  @objc func closePin(_ sender: Any?) { window?.close() }
  func windowWillClose(_ notification: Notification) { onClose?(self) }
}
