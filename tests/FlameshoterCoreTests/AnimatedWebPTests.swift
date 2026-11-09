// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CWebP
import Testing
import UniformTypeIdentifiers

@testable import Flameshoter
@testable import FlameshoterCore

func animatedWebPFixture() throws -> Data {
  let encoder = try #require(WebPAnimEncoderNew(16, 16, nil))
  defer { WebPAnimEncoderDelete(encoder) }
  var configuration = WebPConfig()
  #expect(WebPConfigInit(&configuration) != 0)
  configuration.lossless = 1
  configuration.exact = 1
  for (index, color) in [[UInt8(255), 0, 0, 255], [0, 0, 255, 255]].enumerated() {
    var picture = WebPPicture()
    #expect(WebPPictureInit(&picture) != 0)
    picture.width = 16
    picture.height = 16
    picture.use_argb = 1
    let pixels = Array(repeating: color, count: 16 * 16).flatMap { $0 }
    let imported = pixels.withUnsafeBufferPointer {
      WebPPictureImportRGBA(&picture, $0.baseAddress, 16 * 4)
    }
    #expect(imported != 0)
    #expect(WebPAnimEncoderAdd(encoder, &picture, index == 0 ? 0 : 400, &configuration) != 0)
    WebPPictureFree(&picture)
  }
  #expect(WebPAnimEncoderAdd(encoder, nil, 1000, nil) != 0)
  var data = WebPData()
  #expect(WebPAnimEncoderAssemble(encoder, &data) != 0)
  let bytes = try #require(data.bytes)
  defer { WebPDataClear(&data) }
  return Data(bytes: bytes, count: data.size)
}

@Test func animatedWebPDecodesFramesWithTheirTimingAndCanRestart() throws {
  let data = try animatedWebPFixture()
  let animation = try #require(AnimatedWebP(data: data))
  #expect(animation.width == 16 && animation.height == 16 && animation.frameCount == 2)
  let first = try #require(animation.nextFrame())
  let second = try #require(animation.nextFrame())
  #expect(first.duration == 0.4 && second.duration == 0.6)
  #expect(
    ScreenColor.sample(first.image, point: CGPoint(x: 8, y: 8), scale: 1)?.string(.hashHex)
      == "#ff0000")
  #expect(
    ScreenColor.sample(second.image, point: CGPoint(x: 8, y: 8), scale: 1)?.string(.hashHex)
      == "#0000ff")
  #expect(animation.nextFrame() == nil)
  animation.reset()
  #expect(animation.nextFrame()?.duration == 0.4)
  #expect(AnimatedWebP(data: Data("invalid".utf8)) == nil)
}

@Test func animatedWebPFramesPreserveEmbeddedColorProfile() throws {
  let original = try animatedWebPFixture() as NSData
  var input = WebPData(
    bytes: original.bytes.assumingMemoryBound(to: UInt8.self), size: original.length)
  let mux = try #require(WebPMuxCreate(&input, 1))
  defer { WebPMuxDelete(mux) }
  let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()) as Data
  let result = profile.withUnsafeBytes { buffer in
    var chunk = WebPData(bytes: buffer.bindMemory(to: UInt8.self).baseAddress, size: buffer.count)
    return WebPMuxSetChunk(mux, "ICCP", &chunk, 1)
  }
  #expect(result == WEBP_MUX_OK)
  var encoded = WebPData()
  #expect(WebPMuxAssemble(mux, &encoded) == WEBP_MUX_OK)
  defer { WebPDataClear(&encoded) }
  let data = Data(bytes: try #require(encoded.bytes), count: encoded.size)
  let decoder = try #require(AnimatedWebP(data: data))
  #expect(try #require(decoder.nextFrame()).image.colorSpace?.copyICCData() as Data? == profile)
  #expect(try #require(decoder.nextFrame()).image.colorSpace?.copyICCData() as Data? == profile)
}

@Test @MainActor func animatedWebPPinsRetainTheOriginalData() async throws {
  _ = NSApplication.shared
  let data = try animatedWebPFixture()
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  board.setData(data, forType: NSPasteboard.PasteboardType(UTType.webP.identifier))
  guard case .animated(let bytes, let type) = try #require(ClipboardPin.contents(of: board).first)
  else {
    Issue.record("Animated WebP was not recognized")
    return
  }
  #expect(bytes == data && type == .webP)
  let controller = ContentPinController(content: .animated(bytes, type))
  controller.show()
  defer { controller.window?.close() }
  let view = try #require(controller.window?.contentView as? NSImageView)
  let first = try #require(view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
  #expect(
    ScreenColor.sample(first, point: CGPoint(x: 8, y: 8), scale: 1)?.string(.hashHex) == "#ff0000")
  var sawBlue = false
  for _ in 0..<20 {
    try await Task.sleep(for: .milliseconds(75))
    if let frame = view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      ScreenColor.sample(frame, point: CGPoint(x: 8, y: 8), scale: 1)?.string(.hashHex) == "#0000ff"
    {
      sawBlue = true
      break
    }
  }
  #expect(sawBlue)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("animation.webp")
  try data.write(to: file)
  board.clearContents()
  #expect(board.writeObjects([file as NSURL]))
  guard
    case .animated(let fileBytes, let fileType) = try #require(
      ClipboardPin.contents(of: board).first)
  else {
    Issue.record("Animated WebP file was not recognized")
    return
  }
  #expect(fileBytes == data && fileType == .webP)
}
