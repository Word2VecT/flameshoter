// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@MainActor private func translationFixture() -> CGImage {
  let image = NSImage(size: CGSize(width: 500, height: 200))
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 500, height: 200).fill()
  ("Hello world" as NSString).draw(at: CGPoint(x: 40, y: 90), withAttributes: [
    .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black,
  ])
  image.unlockFocus()
  return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

private func translationPixels(_ image: CGImage) -> [UInt8] {
  let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                   count: image.width * image.height * 4))
}

@Test @MainActor func translatedImageChangesTextAreaWithoutChangingOtherPixels() throws {
  _ = NSApplication.shared
  let original = translationFixture()
  let line = RecognizedTextLine(text: "Hello world", bounds: CGRect(x: 0.075, y: 0.43, width: 0.38, height: 0.23))
  let result = try TranslationImageRenderer.render(original, lines: [line], translated: ["你好，世界"]).image
  #expect(result.width == original.width && result.height == original.height)
  let before = translationPixels(original)
  let after = translationPixels(result)
  #expect(before != after)
  for y in 0..<20 {
    for x in 0..<20 {
      let index = (y * original.width + x) * 4
      #expect(Array(before[index..<index+4]) == Array(after[index..<index+4]))
    }
  }
  #expect(throws: TranslationDisplayError.self) {
    try TranslationImageRenderer.render(original, lines: [line], translated: [])
  }
}

@Test @MainActor func translatedImageSamplesBackgroundAtTheRecognizedLine() throws {
  let context = CGContext(
    data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(NSColor.red.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
  context.setFillColor(NSColor.blue.cgColor)
  context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
  let original = try #require(context.makeImage())
  let line = RecognizedTextLine(text: "One", bounds: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.2))
  let result = try TranslationImageRenderer.render(original, lines: [line], translated: ["一"]).image
  let pixels = translationPixels(result)
  let x = 48, yFromTop = 100 - 1 - 8
  let index = (yFromTop * 200 + x) * 4
  #expect(pixels[index] > 200 && pixels[index + 2] < 50)
}

@Test @MainActor func translatedImageReportsWhenTextDoesNotFit() throws {
  _ = NSApplication.shared
  let image = translationFixture()
  let line = RecognizedTextLine(text: "Hi", bounds: CGRect(x: 0.1, y: 0.4, width: 0.04, height: 0.08))
  let result = try TranslationImageRenderer.render(
    image, lines: [line], translated: [String(repeating: "A long translation ", count: 20)])
  #expect(result.hasTruncatedText)
}

@Test @MainActor func translatedImageCoversGlyphEdgesOutsideTheRecognitionBox() throws {
  let context = CGContext(
    data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(NSColor.white.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
  context.setFillColor(NSColor.black.cgColor)
  context.fill(CGRect(x: 120, y: 31, width: 12, height: 2))
  let image = try #require(context.makeImage())
  let line = RecognizedTextLine(text: "Text", bounds: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.2))
  let output = try TranslationImageRenderer.render(image, lines: [line], translated: ["一"]).image
  let pixels = translationPixels(output)
  let index = ((100 - 1 - 32) * 200 + 125) * 4
  #expect(pixels[index] > 240 && pixels[index + 1] > 240 && pixels[index + 2] > 240)
}

@Test @MainActor func translationDiscardsResultsFromAnEarlierRequest() throws {
  let coordinator = TranslationCoordinator()
  var received: [String] = []
  coordinator.onResult = { if case .success(let lines) = $0 { received = lines } }
  coordinator.start(lines: ["First"], source: "en", target: "zh")
  let first = try #require(coordinator.pending)
  coordinator.start(lines: ["Second"], source: "en", target: "zh")
  let second = try #require(coordinator.pending)
  coordinator.finish(first, result: .success(["旧结果"]))
  #expect(received.isEmpty)
  coordinator.finish(second, result: .success(["新结果"]))
  #expect(received == ["新结果"])
  let previousVersion = try #require(coordinator.configuration?.version)
  coordinator.start(lines: ["Corrected"], source: "en", target: "zh")
  #expect(try #require(coordinator.configuration?.version) > previousVersion)
}

@Test @MainActor func translationWindowKeepsImageAndTextVisibleAtMinimumSize() throws {
  _ = NSApplication.shared
  let controller = TranslationWindowController(image: translationFixture())
  let window = try #require(controller.window)
  defer { window.close() }
  window.setContentSize(window.minSize)
  window.layoutIfNeeded()
  let split = try #require(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
  #expect(split.arrangedSubviews.count == 2)
  #expect(split.arrangedSubviews.allSatisfy { $0.frame.width >= 195 && $0.frame.height > 150 })
}

@Test @MainActor func largeTranslationImageDoesNotForceWindowOffscreen() throws {
  _ = NSApplication.shared
  let context = CGContext(
    data: nil, width: 2400, height: 900, bitsPerComponent: 8, bytesPerRow: 2400 * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let controller = TranslationWindowController(image: try #require(context.makeImage()))
  let window = try #require(controller.window)
  defer { window.close() }
  window.layoutIfNeeded()
  let split = try #require(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
  #expect(window.frame.width < 1000)
  #expect(split.arrangedSubviews.count == 2)
  #expect(split.arrangedSubviews.allSatisfy { $0.frame.width >= 195 && $0.frame.width < 700 })
}

@Test @MainActor func pinnedImageOffersTranslationUsingItsOriginalPixels() throws {
  _ = NSApplication.shared
  let image = translationFixture()
  let pin = PinWindowController(image: image)
  defer { pin.window?.close() }
  var received: CGImage?
  pin.onTranslate = { received = $0 }
  let event = try #require(NSEvent.mouseEvent(
    with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  let menu = try #require(pin.imageView.menu(for: event))
  #expect(menu.items.contains { $0.action == #selector(PinWindowController.translateImage(_:)) })
  pin.translateImage(nil)
  #expect(received === image)
}

@Test func translationUpgradePreservesExistingShortcut() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 10
  old.tools = [.copy]
  old.shortcuts["TYPE_COPY"] = Shortcut(12, [.option])
  try JSONEncoder().encode(old).write(to: url)
  let updated = SettingsStore(url: url).preferences
  #expect(updated.tools == [.copy, .translate])
  #expect(updated.shortcut("TYPE_COPY") == Shortcut(12, [.option]))
  #expect(updated.shortcut(Tool.translate.legacyName) == nil)
}
