// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import ScreenCaptureKit

struct RecordingOptions {
  var framesPerSecond = 24
  var showsCursor = true
  var systemAudio = false
  var microphone = false

  func configuration(selection: CGRect, scale: CGFloat) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = selection
    // H.264 uses even dimensions. Keep the full selected rectangle in the output.
    configuration.width = max(2, Int((selection.width * scale).rounded()) / 2 * 2)
    configuration.height = max(2, Int((selection.height * scale).rounded()) / 2 * 2)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
    configuration.showsCursor = showsCursor
    configuration.capturesAudio = systemAudio
    configuration.captureMicrophone = microphone
    configuration.excludesCurrentProcessAudio = true
    return configuration
  }
}

enum RecordingMovie {
  static func combine(_ urls: [URL], into destination: URL) async throws -> URL {
    guard let first = urls.first else { throw RecordingError.empty }
    if urls.count == 1 { return first }
    let composition = AVMutableComposition()
    var video: AVMutableCompositionTrack?
    var audio: [AVMutableCompositionTrack] = []
    var position = CMTime.zero
    for url in urls {
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration)
      guard duration.isNumeric && duration > .zero else { throw RecordingError.empty }
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let sourceVideo = videoTracks.first else { throw RecordingError.empty }
      if video == nil {
        video = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        video?.preferredTransform = try await sourceVideo.load(.preferredTransform)
      }
      guard let video else { throw RecordingError.export }
      try await insert(sourceVideo, into: video, duration: duration, at: position)
      for (index, source) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
        if audio.count <= index {
          guard
            let track = composition.addMutableTrack(
              withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          else { throw RecordingError.export }
          audio.append(track)
        }
        try await insert(source, into: audio[index], duration: duration, at: position)
      }
      position = CMTimeAdd(position, duration)
    }
    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetPassthrough)
    else { throw RecordingError.export }
    try await exporter.export(to: destination, as: .mp4)
    return destination
  }

  private static func insert(
    _ source: AVAssetTrack, into destination: AVMutableCompositionTrack, duration: CMTime,
    at position: CMTime
  ) async throws {
    let range = CMTimeRangeGetIntersection(
      try await source.load(.timeRange), otherRange: CMTimeRange(start: .zero, duration: duration))
    guard range.isValid, range.duration > .zero else { return }
    try destination.insertTimeRange(range, of: source, at: CMTimeAdd(position, range.start))
  }
}

enum RecordingError: LocalizedError {
  case empty, export, microphonePermission
  var errorDescription: String? {
    switch self {
    case .empty: return "No recording frames were captured."
    case .export: return "Unable to prepare the recording."
    case .microphonePermission: return "Microphone access is required to record microphone audio."
    }
  }
}
