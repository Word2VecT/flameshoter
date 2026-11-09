// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Vision

public enum LongCaptureDirection: Sendable {
  case vertical, horizontal
}

public struct LongCaptureSegment {
  public let image: CGImage
  public let position: Int
}

public enum LongCaptureUpdate: Equatable {
  case unchanged, moved, extended, mismatch
}

/// Retains only newly exposed strips; a failed match leaves the last good frame intact.
public final class LongCapture {
  public let direction: LongCaptureDirection
  public private(set) var segments: [LongCaptureSegment]
  public private(set) var position = 0
  public private(set) var lowerBound = 0
  public private(set) var upperBound: Int
  public var autoTrimOnReverse: Bool
  private var growthDirection: Int?
  private var reference: CGImage

  public init(image: CGImage, direction: LongCaptureDirection, autoTrimOnReverse: Bool = false) {
    self.direction = direction
    self.autoTrimOnReverse = autoTrimOnReverse
    reference = image
    upperBound = direction == .vertical ? image.height : image.width
    segments = [LongCaptureSegment(image: image, position: 0)]
  }

  public var length: Int { upperBound - lowerBound }
  public var frameLength: Int { direction == .vertical ? reference.height : reference.width }
  public var crossLength: Int { direction == .vertical ? reference.width : reference.height }

  public func append(_ image: CGImage) throws -> LongCaptureUpdate {
    guard image.width == reference.width, image.height == reference.height,
      let distance = try LongCaptureMatcher.distance(
        from: reference, to: image, direction: direction)
    else { return .mismatch }
    let newPosition = position + distance
    var extended = false
    if newPosition < lowerBound {
      let count = lowerBound - newPosition
      guard let strip = image.cropping(to: rectangle(start: 0, length: count)) else {
        throw ImageError.renderFailed
      }
      segments.insert(LongCaptureSegment(image: strip, position: newPosition), at: 0)
      lowerBound = newPosition
      extended = true
    }
    if newPosition + frameLength > upperBound {
      let count = newPosition + frameLength - upperBound
      guard let strip = image.cropping(to: rectangle(start: frameLength - count, length: count))
      else {
        throw ImageError.renderFailed
      }
      segments.append(LongCaptureSegment(image: strip, position: upperBound))
      upperBound += count
      extended = true
    }
    position = newPosition
    reference = image
    if extended && growthDirection == nil { growthDirection = distance > 0 ? 1 : -1 }
    if autoTrimOnReverse, let growthDirection, distance * growthDirection < 0 {
      if growthDirection > 0 { try trimAfterCurrent() } else { try trimBeforeCurrent() }
    }
    return extended ? .extended : distance == 0 ? .unchanged : .moved
  }

  private func rectangle(start: Int, length: Int) -> CGRect {
    direction == .vertical
      ? CGRect(x: 0, y: start, width: crossLength, height: length)
      : CGRect(x: start, y: 0, width: length, height: crossLength)
  }

  public func trimBeforeCurrent() throws {
    try trim(from: position, to: upperBound)
  }
  public func trimAfterCurrent() throws {
    try trim(from: lowerBound, to: position + frameLength)
  }
  private func trim(from start: Int, to end: Int) throws {
    let lower = max(lowerBound, start)
    let upper = min(upperBound, end)
    guard lower < upper else { return }
    var retained: [LongCaptureSegment] = []
    for segment in segments {
      let segmentLength = direction == .vertical ? segment.image.height : segment.image.width
      let first = max(lower, segment.position)
      let last = min(upper, segment.position + segmentLength)
      guard first < last else { continue }
      let local = first - segment.position
      let count = last - first
      let rect =
        direction == .vertical
        ? CGRect(x: 0, y: local, width: crossLength, height: count)
        : CGRect(x: local, y: 0, width: count, height: crossLength)
      guard let image = segment.image.cropping(to: rect) else { throw ImageError.renderFailed }
      retained.append(LongCaptureSegment(image: image, position: first))
    }
    segments = retained
    lowerBound = lower
    upperBound = upper
  }

  public func image() throws -> CGImage {
    let width = direction == .vertical ? crossLength : length
    let height = direction == .vertical ? length : crossLength
    let space =
      reference.colorSpace?.model == .rgb
      ? reference.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ImageError.renderFailed }
    context.interpolationQuality = .none
    for segment in segments {
      let offset = segment.position - lowerBound
      let rect =
        direction == .vertical
        ? CGRect(
          x: 0, y: height - offset - segment.image.height,
          width: segment.image.width, height: segment.image.height)
        : CGRect(x: offset, y: 0, width: segment.image.width, height: segment.image.height)
      context.draw(segment.image, in: rect)
    }
    guard let result = context.makeImage() else { throw ImageError.renderFailed }
    return result
  }
}

enum LongCaptureMatcher {
  static func distance(from old: CGImage, to new: CGImage, direction: LongCaptureDirection) throws
    -> Int?
  {
    if score(old, new, offset: 0, direction: direction)?.error == 0 { return 0 }
    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: old)
    try VNImageRequestHandler(cgImage: new).perform([request])
    guard let transform = request.results?.first?.alignmentTransform else { return nil }
    let proposed = Int((direction == .vertical ? transform.ty : -transform.tx).rounded())
    let side = direction == .vertical ? old.height : old.width
    let candidates = [proposed, proposed - 1, proposed + 1, proposed - 2, proposed + 2, 0]
    var best: (distance: Int, error: Double, contrast: Double)?
    for candidate in candidates where abs(candidate) <= side * 3 / 4 {
      guard let score = score(old, new, offset: candidate, direction: direction) else { continue }
      if best == nil || score.error < best!.error {
        best = (candidate, score.error, score.contrast)
      }
    }
    guard let best, best.error < 5, best.distance == 0 || best.contrast > 3 else { return nil }
    return best.distance
  }

  private static func score(
    _ old: CGImage, _ new: CGImage, offset: Int,
    direction: LongCaptureDirection
  ) -> (error: Double, contrast: Double)? {
    let width = old.width
    let height = old.height
    let startOld = max(0, offset)
    let startNew = max(0, -offset)
    let overlap = (direction == .vertical ? height : width) - abs(offset)
    guard overlap > 0 else { return nil }
    let a =
      direction == .vertical
      ? CGRect(x: 0, y: startOld, width: width, height: overlap)
      : CGRect(x: startOld, y: 0, width: overlap, height: height)
    let b =
      direction == .vertical
      ? CGRect(x: 0, y: startNew, width: width, height: overlap)
      : CGRect(x: startNew, y: 0, width: overlap, height: height)
    guard let first = old.cropping(to: a), let second = new.cropping(to: b) else { return nil }
    let sampleWidth = min(256, first.width)
    let sampleHeight = min(256, first.height)
    guard let x = grayscale(first, width: sampleWidth, height: sampleHeight),
      let y = grayscale(second, width: sampleWidth, height: sampleHeight)
    else { return nil }
    var difference = 0.0
    var total = 0.0
    var squared = 0.0
    for index in x.indices {
      let value = Double(x[index])
      difference += Double(abs(Int(x[index]) - Int(y[index])))
      total += value
      squared += value * value
    }
    let count = Double(x.count)
    let mean = total / count
    return (difference / count, sqrt(max(0, squared / count - mean * mean)))
  }

  private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: width * height)
    let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return success ? bytes : nil
  }
}
