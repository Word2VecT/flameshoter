// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ImageIO

@MainActor enum PinPersistence {
  static func record(
    id: UUID, kind: ArchivedPin.Kind, created: Date, closed: Date?, window: NSWindow?
  ) -> ArchivedPin {
    ArchivedPin(
      id: id, kind: kind, created: created, closed: closed, frame: window?.frame ?? .zero,
      opacity: Double(window?.alphaValue ?? 1), payloadFile: "")
  }

  static func restoreWindow(_ window: NSWindow?, from record: ArchivedPin) {
    guard let window else { return }
    let frame = record.frame
    let values = [frame.minX, frame.minY, frame.width, frame.height, CGFloat(record.opacity)]
    if values.allSatisfy(\.isFinite), frame.width >= 40, frame.height >= 40,
      NSScreen.screens.contains(where: {
        $0.visibleFrame.intersection(frame).width >= 40
          && $0.visibleFrame.intersection(frame).height >= 40
      })
    {
      window.setFrame(frame, display: false)
    } else {
      window.center()
    }
    window.alphaValue = record.opacity.isFinite ? CGFloat(min(1, max(0.15, record.opacity))) : 1
  }

  static func image(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    return image
  }
  static func content(_ kind: ArchivedPin.Kind, data: Data) throws -> ContentPin {
    switch kind {
    case .text:
      return .text(
        try NSAttributedString(
          data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil))
    case .color:
      guard let original = String(data: data, encoding: .utf8),
        let color = ScreenColor.parse(original)
      else { throw CocoaError(.fileReadCorruptFile) }
      return .color(color, original)
    case .file:
      guard let string = String(data: data, encoding: .utf8), let url = URL(string: string),
        url.isFileURL
      else { throw CocoaError(.fileReadCorruptFile) }
      return .file(url)
    case .gif:
      guard CGImageSourceCreateWithData(data as CFData, nil) != nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return .animated(data, .gif)
    case .webP:
      guard AnimatedWebP(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
      return .animated(data, .webP)
    case .image: throw CocoaError(.fileReadCorruptFile)
    }
  }
}
