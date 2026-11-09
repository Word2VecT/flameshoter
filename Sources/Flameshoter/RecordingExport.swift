// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import FlameshoterCore
import ImageIO
import UniformTypeIdentifiers

enum RecordingFormat: CaseIterable {
  case mp4, gif, webP
  var title: String {
    switch self {
    case .mp4: return "MP4"
    case .gif: return "GIF"
    case .webP: return "WebP"
    }
  }
  var type: UTType {
    switch self {
    case .mp4: return .mpeg4Movie
    case .gif: return .gif
    case .webP: return .webP
    }
  }
  var fileExtension: String {
    switch self {
    case .mp4: return "mp4"
    case .gif: return "gif"
    case .webP: return "webp"
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
    let count = max(1, Int(ceil(seconds * Double(framesPerSecond))))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let gif: CGImageDestination?
    if format == .gif {
      gif = CGImageDestinationCreateWithURL(
        destination as CFURL, UTType.gif.identifier as CFString, count, nil)
      guard let gif else { throw RecordingError.export }
      CGImageDestinationSetProperties(
        gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    } else {
      gif = nil
    }
    var webP: AnimatedWebPEncoder?
    for index in 0..<count {
      try Task.checkCancellation()
      let offset = Double(index) / Double(framesPerSecond)
      let time = CMTimeAdd(first, CMTime(seconds: offset, preferredTimescale: 60_000))
      let image = try await generator.image(at: time).image
      let remaining = min(1 / Double(framesPerSecond), seconds - offset)
      if let gif {
        // GIF stores delays in hundredths of a second. Round cumulative times so
        // fractional frame delays do not make the whole animation run faster.
        let beginning = (offset * 100).rounded()
        let ending = ((offset + remaining) * 100).rounded()
        let delay = max(1, ending - beginning) / 100
        let properties =
          [
            kCGImagePropertyGIFDictionary: [
              kCGImagePropertyGIFDelayTime: delay,
              kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
          ] as CFDictionary
        CGImageDestinationAddImage(gif, image, properties)
      } else {
        if webP == nil { webP = try AnimatedWebPEncoder(width: image.width, height: image.height) }
        try webP?.add(image, at: Int((offset * 1000).rounded()))
      }
      progress(Double(index + 1) / Double(count))
    }
    try Task.checkCancellation()
    if let gif {
      guard CGImageDestinationFinalize(gif) else { throw RecordingError.export }
    } else {
      guard let webP else { throw RecordingError.empty }
      try webP.data(duration: max(1, Int((seconds * 1000).rounded()))).write(
        to: destination, options: .atomic)
    }
  }

  static func install(_ staged: URL, at destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
    } else {
      try FileManager.default.moveItem(at: staged, to: destination)
    }
  }
}
