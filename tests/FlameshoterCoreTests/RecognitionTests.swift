// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import Testing

@testable import Flameshoter

@MainActor private func textFixture() -> CGImage {
  let image = NSImage(size: NSSize(width: 900, height: 220))
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 900, height: 220).fill()
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black,
  ]
  ("Flameshoter 123" as NSString).draw(at: NSPoint(x: 35, y: 120), withAttributes: attributes)
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

@Test @MainActor func localRecognitionReadsEnglishChineseAndQRCodes() async throws {
  _ = NSApplication.shared
  let analysis = try await ImageRecognition.text(textFixture())
  #expect(analysis.transcript.contains("Flameshoter 123"))
  #expect(analysis.transcript.contains("截图测试"))
  #expect(try await ImageRecognition.qrCodes(qrFixture("https://example.com/pixpin"))
    == ["https://example.com/pixpin"])
  #expect(try await ImageRecognition.qrCodes(textFixture()).isEmpty)
}

@Test @MainActor func pinnedTextIsInteractiveAndBlankImageSpaceStillDrags() async throws {
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
