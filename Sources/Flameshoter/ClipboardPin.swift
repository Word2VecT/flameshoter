// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ImageIO
import UniformTypeIdentifiers

enum ClipboardPinContent {
  case image(CGImage)
  case animated(Data, UTType)
  case text(NSAttributedString)
  case color(ScreenColor, String)
  case file(URL)
}

@MainActor enum ClipboardPin {
  static func contents(of board: NSPasteboard) -> [ClipboardPinContent] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let files = (board.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    if !files.isEmpty {
      return files.map { url in
        if url.pathExtension.lowercased() == "webp", let data = try? Data(contentsOf: url),
          let animation = AnimatedWebP(data: data), animation.frameCount > 1
        {
          return .animated(data, .webP)
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
          if CGImageSourceGetType(source) as String? == UTType.gif.identifier,
            CGImageSourceGetCount(source) > 1, let data = try? Data(contentsOf: url)
          {
            return .animated(data, .gif)
          }
          if CGImageSourceGetCount(source) == 1,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
          {
            return .image(image)
          }
        }
        return .file(url)
      }
    }
    let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
    if let data = board.data(forType: gifType),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 1
    {
      return [.animated(data, .gif)]
    }
    let webPType = NSPasteboard.PasteboardType(UTType.webP.identifier)
    if let data = board.data(forType: webPType),
      let animation = AnimatedWebP(data: data), animation.frameCount > 1
    {
      return [.animated(data, .webP)]
    }
    for type in [
      NSPasteboard.PasteboardType.png, .tiff, gifType,
      NSPasteboard.PasteboardType(UTType.jpeg.identifier),
      NSPasteboard.PasteboardType(UTType.webP.identifier),
    ] {
      if let data = board.data(forType: type),
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      {
        return [.image(image)]
      }
    }
    if let text = board.string(forType: .string) {
      if let color = ScreenColor.parse(text) { return [.color(color, text)] }
      if let rtf = board.data(forType: .rtf),
        let formatted = try? NSAttributedString(
          data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil)
      {
        return [.text(formatted)]
      }
      return [.text(NSAttributedString(string: text))]
    }
    return []
  }
}
