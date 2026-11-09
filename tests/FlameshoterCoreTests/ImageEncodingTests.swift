// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import AppKit
import CWebP
import ImageIO
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

private func encodingFixture(space: CFString = CGColorSpace.sRGB, opaque: Bool = false) -> CGImage {
  let width = 256
  let height = 192
  var bytes = [UInt8]()
  for y in 0..<height {
    for x in 0..<width {
      bytes += [UInt8(x), UInt8(y), UInt8((x + y) % 256), opaque ? 255 : [0, 1, 99, 255][(x / 32) % 4]]
    }
  }
  return CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
    space: CGColorSpace(name: space)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
    shouldInterpolate: false, intent: .defaultIntent)!
}

private func decodedImage(_ data: Data) throws -> CGImage {
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func rgba(_ image: CGImage) throws -> Data {
  var format = vImage_CGImageFormat(
    bitsPerComponent: 8, bitsPerPixel: 32,
    colorSpace: Unmanaged.passUnretained(image.colorSpace!),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), version: 0,
    decode: nil, renderingIntent: .defaultIntent)
  var buffer = vImage_Buffer()
  #expect(vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, 0) == kvImageNoError)
  defer { free(buffer.data) }
  var bytes = Data()
  for row in 0..<image.height {
    bytes.append(Data(bytes: buffer.data + row * buffer.rowBytes, count: image.width * 4))
  }
  return bytes
}

@Suite(.serialized) struct ImageEncodingTests {
  @Test func pngOptimizationPreservesPixelsAndColorProfiles() async throws {
    for space in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
      let image = encodingFixture(space: space)
      let original = try await ImageEncoder.encode(image, optimize: false)
      let optimized = try await ImageEncoder.encode(image, optimize: true)
      #expect(optimized.count < original.count)
      let before = try decodedImage(original)
      let after = try decodedImage(optimized)
      #expect(try rgba(before) == rgba(after))
      #expect(before.colorSpace?.copyICCData() == after.colorSpace?.copyICCData())
      #expect(before.width == after.width && before.height == after.height)
    }
  }

  @Test func pngOptimizationKeepsSixteenBitPrecision() async throws {
    let width = 32
    let samples = (0..<(width * width * 4)).map { UInt16(($0 * 1237) % 65536) }
    let bytes = samples.withUnsafeBytes { Data($0) }
    let image = try #require(
      CGImage(
        width: width, height: width, bitsPerComponent: 16, bitsPerPixel: 64,
        bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
          .union(.byteOrder16Little),
        provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent))
    let original = try decodedImage(await ImageEncoder.encode(image, optimize: false))
    let optimized = try decodedImage(await ImageEncoder.encode(image))
    #expect(original.bitsPerComponent == 16)
    #expect(optimized.bitsPerComponent == 16)
    #expect(original.dataProvider?.data == optimized.dataProvider?.data)
    #expect(throws: ImageError.self) { try ImageEncoder.data(image, format: "webp") }
  }

  @Test func webPIsLosslessIncludingHiddenRGBAndICC() async throws {
    for space in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
      let image = encodingFixture(space: space)
      let source = try rgba(image)
      let original = try await ImageEncoder.encode(image, format: "webp", optimize: false)
      let optimized = try await ImageEncoder.encode(image, format: "webp", optimize: true)
      #expect(optimized.count <= original.count)
      for data in [original, optimized] {
        var width: Int32 = 0
        var height: Int32 = 0
        let bytes = data.withUnsafeBytes {
          WebPDecodeRGBA($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &width, &height)
        }
        let pixels = try #require(bytes)
        defer { WebPFree(pixels) }
        #expect(Data(bytes: pixels, count: Int(width * height * 4)) == source)
        let decoded = try decodedImage(data)
        #expect(decoded.width == image.width && decoded.height == image.height)
        #expect(decoded.colorSpace?.copyICCData() == image.colorSpace?.copyICCData())
        // VP8L stores the lossless bitstream; the profile remains in its ICCP chunk.
        #expect(data.range(of: Data("VP8L".utf8)) != nil)
        #expect(data.range(of: Data("ICCP".utf8)) != nil)
      }
    }
  }

  @Test @MainActor func clipboardUsesTheCompressedPNGBytes() async throws {
    let image = encodingFixture()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    for optimize in [false, true] {
      try await ImageRenderer.copy(image, optimize: optimize, to: board)
      let actual = try #require(board.data(forType: .png))
      let original = try await ImageEncoder.encode(image, optimize: false)
      #expect(try rgba(decodedImage(actual)) == rgba(decodedImage(original)))
      if optimize { #expect(actual.count < original.count) } else { #expect(actual == original) }
    }
  }

  @Test @MainActor func savingWebPWorksForExplicitPathsAndPreferredFormat() async throws {
    #expect(Files.supportedFormats.contains { $0.0 == "webp" })
    let store = Environment.shared.settings
    let previous = store.preferences
    defer { store.update { $0 = previous } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.set("saveAsFileExtension", "webp")
    let image = encodingFixture()
    for optimize in [false, true] {
      store.set("losslessCompression", optimize)
      let saved = try #require(await Files.save(image, path: directory.path, filename: "截图"))
      #expect(saved.pathExtension == "webp")
      #expect(
        try Data(contentsOf: saved) == ImageEncoder.data(image, format: "webp", optimize: optimize))
    }
    store.set("saveAsFileExtension", "png")
    let explicit = directory.appendingPathComponent("explicit.webp")
    #expect(try await Files.save(image, path: explicit.path) == explicit)
    #expect(try decodedImage(Data(contentsOf: explicit)).width == image.width)
  }

  @Test @MainActor func savesPDFAndAVIFWithUsableImageContent() async throws {
    let store = Environment.shared.settings
    let previous = store.preferences
    defer { store.update { $0 = previous } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = encodingFixture(opaque: true)
    #expect(Files.supportedFormats.contains { $0.0 == "pdf" })
    store.set("saveAsFileExtension", "pdf")
    #expect(store.loadError == nil)
    let url = try #require(await Files.save(image, path: directory.path, filename: "capture"))
    #expect(url.pathExtension == "pdf")
    let document = try #require(CGPDFDocument(url as CFURL))
    let page = try #require(document.page(at: 1))
    #expect(document.numberOfPages == 1)
    #expect(page.getBoxRect(.mediaBox).size == CGSize(width: image.width, height: image.height))
    let context = try #require(CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.drawPDFPage(page)
    let rendered = try #require(context.makeImage())
    #expect(try rgba(rendered) == rgba(image))

    let transparent = encodingFixture()
    let transparentPDF = try ImageEncoder.data(transparent, format: "pdf")
    let provider = try #require(CGDataProvider(data: transparentPDF as CFData))
    let transparentPage = try #require(CGPDFDocument(provider)?.page(at: 1))
    func bitmap() throws -> CGContext {
      try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    let expected = try bitmap()
    expected.draw(transparent, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let actual = try bitmap()
    actual.drawPDFPage(transparentPage)
    #expect(expected.makeImage()?.dataProvider?.data == actual.makeImage()?.dataProvider?.data)

    if Files.supportedFormats.contains(where: { $0.0 == "avif" }) {
      let explicit = directory.appendingPathComponent("capture.avif")
      #expect(try await Files.save(image, path: explicit.path) == explicit)
      let decoded = try decodedImage(Data(contentsOf: explicit))
      #expect(decoded.width == image.width && decoded.height == image.height)
    }
  }

  @Test func compressionSettingSurvivesJSONAndINI() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    #expect(store.preferences.bool("losslessCompression"))
    store.set("losslessCompression", false)
    store.set("saveAsFileExtension", "webp")
    let loaded = SettingsStore(url: store.url)
    #expect(!loaded.preferences.bool("losslessCompression"))
    #expect(loaded.preferences.string("saveAsFileExtension") == "webp")
    let ini = root.appendingPathComponent("settings.ini")
    try store.exportFile(ini)
    let imported = try SettingsStore.parseINI(String(contentsOf: ini, encoding: .utf8))
    #expect(!imported.bool("losslessCompression"))
    #expect(imported.string("saveAsFileExtension") == "webp")
  }
}
