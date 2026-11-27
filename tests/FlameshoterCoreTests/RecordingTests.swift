// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import ImageIO
import Synchronization
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

private func recordingFixture(_ url: URL, red: UInt8, blue: UInt8) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 64,
      AVVideoHeightKey: 64,
    ])
  let adapter = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64,
      kCVPixelBufferHeightKey as String: 64,
    ])
  #expect(writer.canAdd(input))
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  for frame in 0..<10 {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<64 {
      for x in 0..<64 {
        let pixel = base.advanced(by: y * row + x * 4)
        pixel[0] = blue
        pixel[1] = 0
        pixel[2] = red
        pixel[3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    #expect(
      adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
  }
  writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

private func recordingFixtureWithAudio(video: URL, audio: URL, output: URL) async throws {
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
  buffer.frameLength = 48_000
  let samples = try #require(buffer.floatChannelData).pointee
  for i in 0..<Int(buffer.frameLength) {
    samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000) * 0.2)
  }
  let file = try AVAudioFile(forWriting: audio, settings: format.settings)
  try file.write(from: buffer)
  file.close()
  let videoAsset = AVURLAsset(url: video)
  let audioAsset = AVURLAsset(url: audio)
  let videoSource = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
  let audioSource = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
  let composition = AVMutableComposition()
  let videoTrack = try #require(
    composition.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
  try videoTrack.insertTimeRange(
    CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
    of: videoSource, at: .zero)
  for _ in 0..<2 {
    let audioTrack = try #require(
      composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
    try audioTrack.insertTimeRange(
      CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
      of: audioSource, at: .zero)
  }
  let exporter = try #require(
    AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
  try await exporter.export(to: output, as: .mp4)
}

@Test func recordingConfigurationUsesTheSelectedAreaAndOptions() {
  let options = RecordingOptions(
    framesPerSecond: 30, showsCursor: false, systemAudio: true, microphone: false)
  let region = CGRect(x: 13, y: 21, width: 100.5, height: 81)
  let configuration = options.configuration(selection: region, scale: 2)
  #expect(configuration.sourceRect == region)
  #expect(configuration.width == 200 && configuration.height == 162)
  #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 30))
  #expect(
    !configuration.showsCursor && configuration.capturesAudio && !configuration.captureMicrophone)
  #expect(configuration.excludesCurrentProcessAudio)
}

@Test func recordingSegmentsCombineWithoutThePausedGap() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let first = folder.appendingPathComponent("red.mp4")
  let second = folder.appendingPathComponent("blue.mp4")
  try await recordingFixture(first, red: 255, blue: 0)
  try await recordingFixture(second, red: 0, blue: 255)
  let output = try await RecordingMovie.combine(
    [first, second], into: folder.appendingPathComponent("result.mp4"))
  let asset = AVURLAsset(url: output)
  let duration = try await asset.load(.duration).seconds
  #expect(duration > 1.8 && duration < 2.2)
  let generator = AVAssetImageGenerator(asset: asset)
  let red = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
  let blue = try await generator.image(at: CMTime(seconds: 1.4, preferredTimescale: 600)).image
  let firstColor = try #require(ScreenColor.sample(red, point: CGPoint(x: 30, y: 30), scale: 1))
  let secondColor = try #require(ScreenColor.sample(blue, point: CGPoint(x: 30, y: 30), scale: 1))
  #expect(firstColor.red > 220 && firstColor.blue < 30)
  #expect(secondColor.blue > 220 && secondColor.red < 30)
}

@Test func combiningRecordingSegmentsKeepsSeparateAudioTracks() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let video = folder.appendingPathComponent("video.mp4")
  let first = folder.appendingPathComponent("first.mp4")
  let second = folder.appendingPathComponent("second.mp4")
  try await recordingFixture(video, red: 255, blue: 0)
  try await recordingFixtureWithAudio(
    video: video, audio: folder.appendingPathComponent("tone.wav"), output: first)
  try FileManager.default.copyItem(at: first, to: second)
  let originalTracks = try await AVURLAsset(url: first).loadTracks(withMediaType: .audio)
  #expect(originalTracks.count == 2)
  let output = try await RecordingMovie.combine(
    [first, second], into: folder.appendingPathComponent("combined.mp4"))
  let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
  #expect(tracks.count == 2)
  for track in tracks { #expect(try await track.load(.timeRange).duration.seconds > 1.8) }
}

@Test func recordingExportsTrimmedGIFAndLosslessAnimatedWebP() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let first = folder.appendingPathComponent("red.mp4")
  let second = folder.appendingPathComponent("blue.mp4")
  try await recordingFixture(first, red: 255, blue: 0)
  try await recordingFixture(second, red: 0, blue: 255)
  let movie = try await RecordingMovie.combine(
    [first, second], into: folder.appendingPathComponent("movie.mp4"))
  let start = CMTime(seconds: 0.25, preferredTimescale: 600)
  let end = CMTime(seconds: 1.75, preferredTimescale: 600)
  let gif = folder.appendingPathComponent("movie.gif")
  try await RecordingExport.write(
    movie: movie, to: gif, format: .gif, from: start, to: end, framesPerSecond: 4
  ) { _ in }
  let gifSource = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
  #expect(CGImageSourceGetCount(gifSource) == 6)
  let gifFirst = try #require(CGImageSourceCreateImageAtIndex(gifSource, 0, nil))
  let gifLast = try #require(CGImageSourceCreateImageAtIndex(gifSource, 5, nil))
  #expect(
    try #require(ScreenColor.sample(gifFirst, point: CGPoint(x: 30, y: 30), scale: 1)).red > 220)
  #expect(
    try #require(ScreenColor.sample(gifLast, point: CGPoint(x: 30, y: 30), scale: 1)).blue > 220)
  let gif24 = folder.appendingPathComponent("movie-24fps.gif")
  try await RecordingExport.write(
    movie: movie, to: gif24, format: .gif, from: start, to: end, framesPerSecond: 24
  ) { _ in }
  let gif24Source = try #require(CGImageSourceCreateWithURL(gif24 as CFURL, nil))
  var gifDuration = 0.0
  for index in 0..<CGImageSourceGetCount(gif24Source) {
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(gif24Source, index, nil) as? [CFString: Any])
    let info = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
    gifDuration += try #require(
      (info[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue)
  }
  #expect(abs(gifDuration - 1.5) < 0.011)
  let webP = folder.appendingPathComponent("movie.webp")
  try await RecordingExport.write(
    movie: movie, to: webP, format: .webP, from: start, to: end, framesPerSecond: 4
  ) { _ in }
  let animation = try #require(AnimatedWebP(data: Data(contentsOf: webP)))
  var images: [CGImage] = []
  var duration = 0.0
  while let frame = animation.nextFrame() {
    images.append(frame.image)
    duration += frame.duration
  }
  #expect(duration == 1.5)
  let firstFrame = try #require(images.first)
  let lastFrame = try #require(images.last)
  #expect(
    try #require(ScreenColor.sample(firstFrame, point: CGPoint(x: 30, y: 30), scale: 1)).red > 220)
  #expect(
    try #require(ScreenColor.sample(lastFrame, point: CGPoint(x: 30, y: 30), scale: 1)).blue > 220)
}

@Test func recordingExportsLoopingAPNGWithTrimmedFrameTiming() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let red = folder.appendingPathComponent("red.mp4")
  let blue = folder.appendingPathComponent("blue.mp4")
  try await recordingFixture(red, red: 255, blue: 0)
  try await recordingFixture(blue, red: 0, blue: 255)
  let movie = try await RecordingMovie.combine(
    [red, blue], into: folder.appendingPathComponent("both.mp4"))
  let start = CMTime(value: 12, timescale: 24)
  let end = CMTime(value: 87, timescale: 48)
  let destination = folder.appendingPathComponent("clip").appendingPathExtension(
    RecordingFormat.apng.fileExtension)
  let updates = Mutex<[Double]>([])
  try await RecordingExport.write(
    movie: movie, to: destination, format: .apng, from: start, to: end, framesPerSecond: 24
  ) { value in updates.withLock { $0.append(value) } }

  let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
  #expect(CGImageSourceGetType(source) as String? == "public.png")
  #expect(CGImageSourceGetCount(source) == 32)
  let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
  let animation = try #require(properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
  #expect(animation[kCGImagePropertyAPNGLoopCount] as? Int == 0)
  var duration = 0.0
  for index in 0..<CGImageSourceGetCount(source) {
    let frameProperties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
    let png = try #require(frameProperties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
    let delay = try #require(png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
    #expect(abs(delay - (index == 31 ? 1.0 / 48 : 1.0 / 24)) < 0.0011)
    duration += delay
  }
  #expect(abs(duration - (end - start).seconds) < 0.001)
  for (index, isRed) in [(0, true), (11, true), (12, false), (31, false)] {
    let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
    let color = try #require(ScreenColor.sample(image, point: CGPoint(x: 30, y: 30), scale: 1))
    #expect(isRed ? color.red > 220 && color.blue < 30 : color.blue > 220 && color.red < 30)
  }
  #expect(updates.withLock { $0 } == (1...20).map { Double($0) / 20 })
}

@Test func subframeAPNGTrimStillContainsAnimationTiming() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let movie = folder.appendingPathComponent("red.mp4")
  try await recordingFixture(movie, red: 255, blue: 0)
  let clip = folder.appendingPathComponent("short.png")
  try await RecordingExport.write(
    movie: movie, to: clip, format: .apng, from: .zero,
    to: CMTime(value: 30, timescale: 1000), framesPerSecond: 24
  ) { _ in }
  let source = try #require(CGImageSourceCreateWithURL(clip as CFURL, nil))
  #expect(CGImageSourceGetCount(source) == 2)
  for index in 0..<CGImageSourceGetCount(source) {
    let frame = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
    let png = try #require(frame[kCGImagePropertyPNGDictionary] as? [CFString: Any])
    let delay = try #require(png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
    #expect(abs(delay - 0.015) < 0.0001)
  }
}

@Test func savingRecordingReplacesTheChosenFile() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let destination = folder.appendingPathComponent("recording.mp4")
  let staged = folder.appendingPathComponent("staged.mp4")
  try Data("old".utf8).write(to: destination)
  try Data("new".utf8).write(to: staged)
  try RecordingExport.install(staged, at: destination)
  #expect(try Data(contentsOf: destination) == Data("new".utf8))
  #expect(!FileManager.default.fileExists(atPath: staged.path))
}
