// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Flameshoter
@testable import FlameshoterCore

@Test @MainActor func clipboardPinsRecognizeImagesTextColorsAndFiles() throws {
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  let image = try #require(
    CGContext(
      data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage())
  board.clearContents()
  board.setData(try ImageEncoder.data(image), forType: .png)
  guard case .image(let decoded) = try #require(ClipboardPin.contents(of: board).first) else {
    Issue.record("Clipboard PNG was not recognized as an image")
    return
  }
  #expect(decoded.width == 8 && decoded.height == 6)

  let output = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
  let properties =
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary
  CGImageDestinationAddImage(destination, image, properties)
  CGImageDestinationAddImage(destination, image, properties)
  #expect(CGImageDestinationFinalize(destination))
  board.clearContents()
  board.setData(output as Data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
  guard
    case .animated(let animation, let type) = try #require(ClipboardPin.contents(of: board).first)
  else {
    Issue.record("Animated GIF was not preserved")
    return
  }
  #expect(animation == output as Data)
  #expect(type == .gif)
  let animatedPin = ContentPinController(content: .animated(animation, .gif))
  let animatedView = try #require(animatedPin.window?.contentView as? NSImageView)
  #expect(animatedView.animates)
  #expect(
    CGImageSourceGetCount(try #require(CGImageSourceCreateWithData(animation as CFData, nil))) == 2)

  board.clearContents()
  board.setString("hello 文字", forType: .string)
  guard case .text(let text) = try #require(ClipboardPin.contents(of: board).first) else {
    Issue.record("Clipboard text was not recognized")
    return
  }
  #expect(text.string == "hello 文字")

  let styled = NSAttributedString(
    string: "Styled text", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
  let rtf = try styled.data(
    from: NSRange(location: 0, length: styled.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
  board.clearContents()
  board.setString(styled.string, forType: .string)
  board.setData(rtf, forType: .rtf)
  guard case .text(let formatted) = try #require(ClipboardPin.contents(of: board).first) else {
    Issue.record("Rich clipboard text was not recognized")
    return
  }
  let font = try #require(formatted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
  #expect(font.fontDescriptor.symbolicTraits.contains(.bold))

  for value in ["#0485f7", "rgb(4, 133, 247)", "#48f"] {
    board.clearContents()
    board.setString(value, forType: .string)
    guard
      case .color(let color, let original) = try #require(ClipboardPin.contents(of: board).first)
    else {
      Issue.record("Clipboard color was not recognized")
      return
    }
    #expect(original == value)
    #expect(
      value == "#48f" ? color.string(.hashHex) == "#4488ff" : color.string(.hashHex) == "#0485f7")
  }
  #expect(ScreenColor.parse("rgb(1,,2,3)") == nil)
  #expect(ScreenColor.parse("rgb(999, 0, 0)") == nil)

  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("document.txt")
  try Data("fixture".utf8).write(to: file)
  board.clearContents()
  #expect(board.writeObjects([file as NSURL]))
  guard case .file(let result) = try #require(ClipboardPin.contents(of: board).first) else {
    Issue.record("Clipboard file was not recognized")
    return
  }
  #expect(result == file)
}

@Test @MainActor func closedClipboardPinsCanBeRestoredWithinTheSession() throws {
  _ = NSApplication.shared
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  board.setString("A pinned note", forType: .string)
  let controller = AppController(command: nil)
  let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
  #expect(controller.pinClipboardContents(of: board))
  let window = try #require(
    NSApp.windows.first {
      !oldWindows.contains(ObjectIdentifier($0)) && $0.windowController is ContentPinController
    })
  #expect(window.isVisible)
  window.close()
  let restore = NSMenuItem(
    title: "", action: #selector(AppController.restoreClosedPin(_:)), keyEquivalent: "")
  #expect(controller.validateMenuItem(restore))
  controller.restoreClosedPin(nil)
  #expect(window.isVisible)
  #expect(!controller.validateMenuItem(restore))
  window.close()
}
