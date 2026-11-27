// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import Testing

@testable import Flameshoter

@MainActor private func textFixture(english: String = "Flameshoter 123") -> CGImage {
  let image = NSImage(size: NSSize(width: 900, height: 220))
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 900, height: 220).fill()
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black,
  ]
  (english as NSString).draw(at: NSPoint(x: 35, y: 120), withAttributes: attributes)
  ("截图测试" as NSString).draw(at: NSPoint(x: 35, y: 35), withAttributes: attributes)
  image.unlockFocus()
  return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

private func qrFixture(_ payload: String) -> CGImage {
  let filter = CIFilter(name: "CIQRCodeGenerator")!
  filter.setValue(Data(payload.utf8), forKey: "inputMessage")
  let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
  let context = CIContext()
  let image = context.createCGImage(code, from: code.extent)!
  let output = CGContext(
    data: nil, width: image.width + 64, height: image.height + 64,
    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  output.setFillColor(NSColor.white.cgColor)
  output.fill(CGRect(x: 0, y: 0, width: image.width + 64, height: image.height + 64))
  output.interpolationQuality = .none
  output.draw(image, in: CGRect(x: 32, y: 32, width: image.width, height: image.height))
  return output.makeImage()!
}

@Test(.requiresVisionAccelerator) @MainActor func systemRecognitionReadsEnglishAndChinese() async throws {
  _ = NSApplication.shared
  let image = textFixture(english: "Capture Settings 123")
  let analysis = try await ImageRecognition.text(image)
  #expect(analysis.transcript.contains("Capture Settings 123"))
  #expect(analysis.transcript.contains("截图测试"))
  let lines = try await ImageRecognition.lines(image)
  #expect(lines.contains(where: { $0.text.contains("Capture Settings 123") }))
  #expect(lines.contains(where: { $0.text.contains("截图测试") }))
  #expect(lines.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.bounds) })
}

@Test @MainActor func systemRecognitionReadsQRPayload() async throws {
  _ = NSApplication.shared
  #expect(try await ImageRecognition.qrCodes(qrFixture("https://example.com/pixpin"))
    == ["https://example.com/pixpin"])
  #expect(try await ImageRecognition.qrCodes(textFixture()).isEmpty)
}

@Test @MainActor func smallOCRShowsAndCopiesBilingualText() async throws {
  _ = NSApplication.shared
  let controller = RecognitionWindowController(image: textFixture(), kind: .text)
  let window = try #require(controller.window)
  defer { window.close() }
  let split = try #require(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
  let scroll = try #require(split.arrangedSubviews.compactMap { $0 as? NSScrollView }.first)
  let result = try #require(scroll.documentView as? NSTextView)
  await controller.recognize()
  #expect(result.isEditable)
  let expected = "Flameshoter 123\n截图测试"
  #expect(result.string == expected)
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  controller.copyText(to: board)
  #expect(board.string(forType: .string) == expected)
  let selection = (result.string as NSString).range(of: "截图测试")
  try #require(selection.location != NSNotFound)
  result.setSelectedRange(selection)
  controller.copyText(to: board)
  #expect(board.string(forType: .string) == "截图测试")
}

@Test func smallOCRReturnsEmptyTextForBlankSelection() async throws {
  let context = try #require(CGContext(
    data: nil, width: 400, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.clear(CGRect(x: 0, y: 0, width: 400, height: 20))
  let blank = try #require(context.makeImage())
  #expect(try await PaddleTextRecognition.shared.transcript(blank).isEmpty)
}

@Test(.requiresVisionAccelerator) @MainActor func recognitionCanUseAnExplicitJapaneseSourceLanguage() async throws {
  _ = NSApplication.shared
  let image = NSImage(size: NSSize(width: 700, height: 180))
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 700, height: 180).fill()
  ("日本語の翻訳テスト" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: [
    .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black,
  ])
  image.unlockFocus()
  let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
  let lines = try await ImageRecognition.lines(cgImage, language: "ja")
  #expect(lines.map(\.text).joined().contains("日本語"))
}

@Test(.requiresVisionAccelerator) @MainActor func pinnedTextIsInteractiveAndBlankImageSpaceStillDrags() async throws {
  _ = NSApplication.shared
  let image = textFixture()
  let pin = PinWindowController(image: image)
  let window = try #require(pin.window)
  defer { window.close() }
  window.layoutIfNeeded()
  let overlay = try #require(pin.imageView.textOverlay)
  overlay.analysis = try await ImageRecognition.text(image)
  let size = overlay.bounds.size
  var textPoint: CGPoint?
  for y in stride(from: CGFloat(2), to: size.height, by: 3) {
    for x in stride(from: CGFloat(2), to: size.width, by: 3) {
      let point = CGPoint(x: x, y: y)
      if overlay.analysisHasText(at: point) {
        textPoint = point
        break
      }
    }
    if textPoint != nil { break }
  }
  let point = try #require(textPoint)
  let viewPoint = CGPoint(x: point.x, y: overlay.isFlipped ? point.y : size.height - point.y)
  let parentPoint = overlay.convert(viewPoint, to: pin.imageView.superview)
  let hit = try #require(pin.imageView.hitTest(parentPoint))
  #expect(hit === overlay || hit.isDescendant(of: overlay))
  let blank = overlay.convert(CGPoint(x: size.width - 2, y: size.height - 2), to: pin.imageView.superview)
  #expect(pin.imageView.hitTest(blank) === pin.imageView)
}
