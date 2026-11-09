// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import AppKit
import CWebP

/// Encodes a sequence of full frames without reducing their decoded pixel values.
public final class AnimatedWebPEncoder {
  private let encoder: OpaquePointer
  private let width: Int
  private let height: Int
  private var profile: Data?
  private var finished = false

  public init(width: Int, height: Int) throws {
    guard width > 0, height > 0, width <= 16_383, height <= 16_383,
      let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), nil)
    else { throw ImageError.encodeFailed }
    self.encoder = encoder
    self.width = width
    self.height = height
  }
  deinit { WebPAnimEncoderDelete(encoder) }

  public func add(_ image: CGImage, at timestamp: Int) throws {
    guard !finished, image.width == width, image.height == height,
      timestamp >= 0, timestamp <= Int(Int32.max)
    else { throw ImageError.encodeFailed }
    let space =
      image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    if profile == nil { profile = space.copyICCData() as Data? }
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
    var configuration = WebPConfig()
    var picture = WebPPicture()
    guard WebPConfigInit(&configuration) != 0, WebPPictureInit(&picture) != 0 else {
      throw ImageError.encodeFailed
    }
    configuration.lossless = 1
    configuration.exact = 1
    configuration.method = 4
    configuration.thread_level = 1
    picture.width = Int32(width)
    picture.height = Int32(height)
    picture.use_argb = 1
    defer { WebPPictureFree(&picture) }
    guard
      WebPPictureImportRGBA(
        &picture, pixels.data.assumingMemoryBound(to: UInt8.self), Int32(pixels.rowBytes)) != 0,
      WebPAnimEncoderAdd(encoder, &picture, Int32(timestamp), &configuration) != 0
    else { throw ImageError.encodeFailed }
  }

  public func data(duration: Int) throws -> Data {
    guard !finished, duration > 0, duration <= Int(Int32.max),
      WebPAnimEncoderAdd(encoder, nil, Int32(duration), nil) != 0
    else { throw ImageError.encodeFailed }
    finished = true
    var animated = WebPData()
    guard WebPAnimEncoderAssemble(encoder, &animated) != 0, animated.bytes != nil else {
      throw ImageError.encodeFailed
    }
    defer { WebPDataClear(&animated) }
    guard let profile else { return Data(bytes: animated.bytes!, count: animated.size) }
    guard let mux = WebPMuxCreate(&animated, 1) else { throw ImageError.encodeFailed }
    defer { WebPMuxDelete(mux) }
    let result = profile.withUnsafeBytes { buffer in
      var chunk = WebPData(bytes: buffer.bindMemory(to: UInt8.self).baseAddress, size: buffer.count)
      return WebPMuxSetChunk(mux, "ICCP", &chunk, 1)
    }
    guard result == WEBP_MUX_OK else { throw ImageError.encodeFailed }
    var output = WebPData()
    guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else {
      throw ImageError.encodeFailed
    }
    defer { WebPDataClear(&output) }
    return Data(bytes: bytes, count: output.size)
  }
}
