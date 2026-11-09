// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import FlameshoterCore

private func scrollFixture(width: Int, height: Int) throws -> CGImage {
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  for y in 0..<height {
    for x in 0..<width {
      let cell = (x / 13) &* 73_856_093 ^ (y / 11) &* 19_349_663
      let value = UInt8(truncatingIfNeeded: (cell &* 1_103_515_245 &+ 12345) >> 16)
      let offset = (y * width + x) * 4
      bytes[offset] = value
      bytes[offset + 1] = UInt8(truncatingIfNeeded: Int(value) &+ x)
      bytes[offset + 2] = UInt8(truncatingIfNeeded: Int(value) &+ y)
      bytes[offset + 3] = 255
    }
  }
  return try #require(
    CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent))
}

private func normalizedPixels(_ image: CGImage) throws -> Data {
  let context = try #require(
    CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.interpolationQuality = .none
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return try #require(context.makeImage()?.dataProvider?.data as Data?)
}

@Test func longCaptureStitchesInBothDirectionsAndRecoversAfterMismatch() throws {
  let image = try scrollFixture(width: 800, height: 800)
  for direction in [LongCaptureDirection.vertical, .horizontal] {
    func frame(_ start: Int) throws -> CGImage {
      let rect =
        direction == .vertical
        ? CGRect(x: 0, y: start, width: 400, height: 400)
        : CGRect(x: start, y: 0, width: 400, height: 400)
      return try #require(image.cropping(to: rect))
    }
    let capture = LongCapture(image: try frame(100), direction: direction)
    #expect(try capture.append(frame(100)) == .unchanged)
    #expect(try capture.append(frame(180)) == .extended)
    #expect(try capture.append(frame(260)) == .extended)
    #expect(try capture.append(frame(180)) == .moved)
    let unrelated = try #require(
      image.cropping(to: CGRect(x: 400, y: 400, width: 400, height: 400)))
    #expect(try capture.append(unrelated) == .mismatch)
    #expect(try capture.append(frame(340)) == .extended)
    #expect(capture.length == 640)
    let expectedRect =
      direction == .vertical
      ? CGRect(x: 0, y: 100, width: 400, height: 640)
      : CGRect(x: 100, y: 0, width: 640, height: 400)
    let expected = try #require(image.cropping(to: expectedRect))
    #expect(try normalizedPixels(capture.image()) == normalizedPixels(expected))
    #expect(try capture.append(frame(180)) == .moved)
    try capture.trimBeforeCurrent()
    try capture.trimAfterCurrent()
    #expect(capture.length == 400)
    #expect(try normalizedPixels(capture.image()) == normalizedPixels(frame(180)))
    #expect(try capture.append(frame(260)) == .extended)
    #expect(capture.length == 480)
    let auto = LongCapture(image: try frame(100), direction: direction, autoTrimOnReverse: true)
    #expect(try auto.append(frame(180)) == .extended)
    #expect(try auto.append(frame(260)) == .extended)
    #expect(try auto.append(frame(180)) == .moved)
    #expect(auto.length == 480)
    #expect(try auto.append(frame(100)) == .moved)
    #expect(auto.length == 400)
    #expect(try normalizedPixels(auto.image()) == normalizedPixels(frame(100)))
  }
}
