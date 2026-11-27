// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import FlameshoterCore
import ImageIO
import UniformTypeIdentifiers

enum RecordingFormat: CaseIterable {
  case mp4, gif, webP, apng
  var title: String {
    switch self {
    case .mp4: return "MP4"
    case .gif: return "GIF"
    case .webP: return "WebP"
    case .apng: return "APNG"
    }
  }
  var type: UTType {
    switch self {
    case .mp4: return .mpeg4Movie
    case .gif: return .gif
    case .webP: return .webP
    case .apng: return .png
    }
  }
  var fileExtension: String {
    switch self {
    case .mp4: return "mp4"
    case .gif: return "gif"
    case .webP: return "webp"
    case .apng: return "png"
    }
  }
}

enum RecordingExport {
  static func write(
    movie: URL, to destination: URL, format: RecordingFormat, from start: CMTime,
    to end: CMTime, framesPerSecond: Int, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let asset = AVURLAsset(url: movie)
    let duration = try await asset.load(.duration)
    let first = start.isValid ? start : .zero
    let last = end.isValid ? end : duration
    guard first.isNumeric, last.isNumeric, first >= .zero, last <= duration, last > first else {
      throw RecordingError.empty
    }
    if format == .mp4 {
      if first == .zero && last == duration {
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: movie, to: destination)
        try Task.checkCancellation()
      } else {
        guard
          let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw RecordingError.export }
        exporter.timeRange = CMTimeRangeFromTimeToTime(start: first, end: last)
        try await exporter.export(to: destination, as: .mp4)
      }
      return
    }
    let seconds = CMTimeSubtract(last, first).seconds
    guard framesPerSecond > 0, seconds.isFinite, seconds > 0,
      seconds * 1000 <= Double(Int32.max), seconds * Double(framesPerSecond) < Double(Int32.max)
    else { throw RecordingError.export }
    let sampleCount = max(1, Int(ceil(seconds * Double(framesPerSecond))))
    // ImageIO emits a static PNG for one frame. Hold a short selection over two
    // frames so it still has animation timing and loop metadata.
    let needsHoldFrame = format == .apng && sampleCount == 1
    let count = needsHoldFrame ? 2 : sampleCount
    let frameRate = needsHoldFrame ? 2 / seconds : Double(framesPerSecond)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let imageDestination: CGImageDestination?
    if format == .gif || format == .apng {
      imageDestination = CGImageDestinationCreateWithURL(
        destination as CFURL, format.type.identifier as CFString, count, nil)
      guard let imageDestination else { throw RecordingError.export }
      let loopProperties =
        format == .gif
        ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
      CGImageDestinationSetProperties(imageDestination, loopProperties as CFDictionary)
    } else {
      imageDestination = nil
    }
    var webP: AnimatedWebPEncoder?
    var lastProgressStep = 0
    for index in 0..<count {
      try Task.checkCancellation()
      let offset = Double(index) / frameRate
      let time =
        needsHoldFrame
        ? first : CMTimeAdd(first, CMTime(seconds: offset, preferredTimescale: 60_000))
      let image = try await generator.image(at: time).image
      if let imageDestination {
        // ImageIO writes GIF in centiseconds and APNG in milliseconds. Rounding
        // cumulative timestamps keeps the final frame aligned with the trim point.
        let ticksPerSecond = format == .gif ? 100.0 : 1000.0
        let beginning = (offset * ticksPerSecond).rounded()
        let nextOffset = min(seconds, Double(index + 1) / frameRate)
        let ending = (nextOffset * ticksPerSecond).rounded()
        let delay = max(1, ending - beginning) / ticksPerSecond
        let properties: [CFString: [CFString: Double]]
        if format == .gif {
          properties = [
            kCGImagePropertyGIFDictionary: [
              kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
          ]
        } else {
          properties = [
            kCGImagePropertyPNGDictionary: [
              kCGImagePropertyAPNGDelayTime: delay,
              kCGImagePropertyAPNGUnclampedDelayTime: delay,
            ]
          ]
        }
        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
      } else {
        if webP == nil { webP = try AnimatedWebPEncoder(width: image.width, height: image.height) }
        try webP?.add(image, at: Int((offset * 1000).rounded()))
      }
      let step = (index + 1) * 20 / count
      if step > lastProgressStep && step < 20 {
        progress(Double(step) / 20)
        lastProgressStep = step
      }
    }
    try Task.checkCancellation()
    if let imageDestination {
      guard CGImageDestinationFinalize(imageDestination) else { throw RecordingError.export }
    } else {
      guard let webP else { throw RecordingError.empty }
      try webP.data(duration: max(1, Int((seconds * 1000).rounded()))).write(
        to: destination, options: .atomic)
    }
    try Task.checkCancellation()
    progress(1)
  }

  static func install(_ staged: URL, at destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
    } else {
      try FileManager.default.moveItem(at: staged, to: destination)
    }
  }
}
