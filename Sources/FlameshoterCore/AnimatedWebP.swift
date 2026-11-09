// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CWebP

/// Decodes one fully composited frame at a time using the bundled libwebp.
public final class AnimatedWebP {
  private let storage: NSData
  private let decoder: OpaquePointer
  private let colorSpace: CGColorSpace
  private var previousTimestamp = 0
  public let width: Int
  public let height: Int
  public let frameCount: Int
  public let loopCount: Int

  public init?(data: Data) {
    let storage = data as NSData
    var input = WebPData(
      bytes: storage.bytes.assumingMemoryBound(to: UInt8.self), size: storage.length)
    guard let decoder = WebPAnimDecoderNew(&input, nil) else { return nil }
    var info = WebPAnimInfo()
    guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else {
      WebPAnimDecoderDelete(decoder)
      return nil
    }
    var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var chunk = WebPChunkIterator()
    if let demux = WebPAnimDecoderGetDemuxer(decoder),
      WebPDemuxGetChunk(demux, "ICCP", 1, &chunk) != 0
    {
      if let bytes = chunk.chunk.bytes {
        let profile = Data(bytes: bytes, count: chunk.chunk.size)
        colorSpace = CGColorSpace(iccData: profile as CFData) ?? colorSpace
      }
      WebPDemuxReleaseChunkIterator(&chunk)
    }
    self.storage = storage
    self.decoder = decoder
    self.colorSpace = colorSpace
    width = Int(info.canvas_width)
    height = Int(info.canvas_height)
    frameCount = Int(info.frame_count)
    loopCount = Int(info.loop_count)
  }

  deinit { WebPAnimDecoderDelete(decoder) }

  public func nextFrame() -> (image: CGImage, duration: TimeInterval)? {
    guard WebPAnimDecoderHasMoreFrames(decoder) != 0 else { return nil }
    var pixels: UnsafeMutablePointer<UInt8>?
    var timestamp: Int32 = 0
    guard WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) != 0, let pixels else { return nil }
    let data = Data(bytes: pixels, count: width * height * 4)
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    let duration = max(0.01, Double(Int(timestamp) - previousTimestamp) / 1000)
    previousTimestamp = Int(timestamp)
    return (image, duration)
  }

  public func reset() {
    WebPAnimDecoderReset(decoder)
    previousTimestamp = 0
  }
}
