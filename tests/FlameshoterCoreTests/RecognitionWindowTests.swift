// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter

@Test @MainActor func recognitionWindowKeepsBothPanesVisibleForLargeImages() throws {
  _ = NSApplication.shared
  let context = try #require(CGContext(
    data: nil, width: 3024, height: 1964, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  let controller = RecognitionWindowController(image: try #require(context.makeImage()), kind: .text)
  let window = try #require(controller.window)
  defer { window.close() }
  window.layoutIfNeeded()
  let split = try #require(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
  #expect(window.frame.width < 1000)
  #expect(window.frame.height < 800)
  #expect(split.subviews.count == 2)
  #expect(split.subviews[0].frame.width >= 160)
  #expect(split.subviews[1].frame.width >= 160)
}
