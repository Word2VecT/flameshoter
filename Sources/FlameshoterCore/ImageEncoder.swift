// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import AppKit
import CWebP
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoder {
  public static func encode(
    _ image: CGImage, format: String = "png", quality: Int = 75, optimize: Bool = true
  ) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      try data(image, format: format, quality: quality, optimize: optimize)
    }.value
  }

  public static func data(
    _ image: CGImage, format: String = "png", quality: Int = 75, optimize: Bool = false
  ) throws -> Data {
    if format.lowercased() == "webp" {
      let original = try webP(image, method: 0)
      guard optimize else { return original }
      let optimized = try webP(image, method: 4)
      return optimized.count < original.count ? optimized : original
    }
    let type: UTType
    switch format.lowercased() {
    case "png": type = .png
    case "jpg", "jpeg": type = .jpeg
    case "tif", "tiff": type = .tiff
    case "bmp": type = .bmp
    default: throw ImageError.unsupportedFormat
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, type.identifier as CFString, 1, nil)
    else { throw ImageError.unsupportedFormat }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageError.encodeFailed }
    let encoded = output as Data
    return optimize && type == .png ? try optimizePNG(encoded) : encoded
  }

  private static func optimizePNG(_ input: Data) throws -> Data {
    let executable: URL
    if ProcessInfo.processInfo.environment["FLAMESHOTER_TEST_CONFIG"] != nil,
      let path = ProcessInfo.processInfo.environment["FLAMESHOTER_TEST_OXIPNG"]
    {
      executable = URL(fileURLWithPath: path)
    } else {
      guard let url = Bundle.main.url(forAuxiliaryExecutable: "oxipng") else {
        throw ImageError.encodeFailed
      }
      executable = url
    }
    let process = Process()
    process.executableURL = executable
    // Preserve metadata and hidden RGB values; never enable --alpha or --strip.
    process.arguments = [
      "--quiet", "--opt", "2", "--threads", "2", "--timeout", "2", "--stdout", "-",
    ]
    let source = Pipe()
    let destination = Pipe()
    process.standardInput = source
    process.standardOutput = destination
    process.standardError = FileHandle.nullDevice
    try process.run()
    // Drain stdout while feeding stdin, including images larger than a pipe buffer.
    DispatchQueue.global(qos: .userInitiated).async {
      try? source.fileHandleForWriting.write(contentsOf: input)
      try? source.fileHandleForWriting.close()
    }
    let output = destination.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, !output.isEmpty else { throw ImageError.encodeFailed }
    return output.count < input.count ? output : input
  }

  private static func webP(_ image: CGImage, method: Int32) throws -> Data {
    // WebP lossless stores 8-bit RGB(A). Never silently reduce higher precision input.
    guard image.bitsPerComponent <= 8 else { throw ImageError.unsupportedFormat }
    let space =
      image.colorSpace?.model == .rgb
      ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    var format = vImage_CGImageFormat(
      bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: Unmanaged.passUnretained(space),
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
      version: 0, decode: nil, renderingIntent: .defaultIntent)
    var pixels = vImage_Buffer()
    guard
      vImageBuffer_InitWithCGImage(&pixels, &format, nil, image, vImage_Flags(kvImageNoFlags))
        == kvImageNoError
    else { throw ImageError.encodeFailed }
    defer { free(pixels.data) }
    var config = WebPConfig()
    var picture = WebPPicture()
    guard WebPConfigInit(&config) != 0, WebPPictureInit(&picture) != 0 else {
      throw ImageError.encodeFailed
    }
    config.lossless = 1
    config.exact = 1
    config.method = method
    config.quality = method == 0 ? 0 : 75
    picture.use_argb = 1
    picture.width = Int32(image.width)
    picture.height = Int32(image.height)
    defer { WebPPictureFree(&picture) }
    guard
      WebPPictureImportRGBA(
        &picture, pixels.data.assumingMemoryBound(to: UInt8.self), Int32(pixels.rowBytes)) != 0
    else { throw ImageError.encodeFailed }
    var writer = WebPMemoryWriter()
    WebPMemoryWriterInit(&writer)
    defer { WebPMemoryWriterClear(&writer) }
    picture.writer = WebPMemoryWrite
    let success = withUnsafeMutablePointer(to: &writer) { pointer in
      picture.custom_ptr = UnsafeMutableRawPointer(pointer)
      return WebPEncode(&config, &picture)
    }
    guard success != 0, let mux = WebPMuxNew() else { throw ImageError.encodeFailed }
    defer { WebPMuxDelete(mux) }
    var bitstream = WebPData(bytes: writer.mem, size: writer.size)
    guard WebPMuxSetImage(mux, &bitstream, 1) == WEBP_MUX_OK else {
      throw ImageError.encodeFailed
    }
    if let profile = space.copyICCData() as Data? {
      let result = profile.withUnsafeBytes { buffer in
        var chunk = WebPData(
          bytes: buffer.bindMemory(to: UInt8.self).baseAddress, size: buffer.count)
        return WebPMuxSetChunk(mux, "ICCP", &chunk, 1)
      }
      guard result == WEBP_MUX_OK else { throw ImageError.encodeFailed }
    }
    var output = WebPData()
    guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else {
      throw ImageError.encodeFailed
    }
    defer { WebPDataClear(&output) }
    return Data(bytes: bytes, count: output.size)
  }
}
