// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import ScreenCaptureKit

@MainActor final class RecordingSegment: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  private let url: URL
  private var stream: SCStream!
  private var output: SCRecordingOutput!
  private var finished: Result<Void, Error>?
  private var continuation: CheckedContinuation<Void, Error>?
  private var stopping = false
  var onFailure: ((Error) -> Void)?

  private init(url: URL) {
    self.url = url
    super.init()
  }

  static func start(
    screen: NSScreen, selection: CGRect, options: RecordingOptions, url: URL
  ) async throws -> RecordingSegment {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let display = content.displays.first(where: { $0.displayID == number.uint32Value })
    else { throw CaptureError.display }
    let ownApplications = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display, excludingApplications: ownApplications, exceptingWindows: [])
    let segment = RecordingSegment(url: url)
    segment.stream = SCStream(
      filter: filter,
      configuration: options.configuration(selection: selection, scale: screen.backingScaleFactor),
      delegate: segment)
    let configuration = SCRecordingOutputConfiguration()
    configuration.outputURL = url
    configuration.outputFileType = .mp4
    if #available(macOS 27, *) { configuration.mixesAudioWithMicrophone = false }
    segment.output = SCRecordingOutput(configuration: configuration, delegate: segment)
    try segment.stream.addRecordingOutput(segment.output)
    try await segment.stream.startCapture()
    if case .failure(let error) = segment.finished { throw error }
    return segment
  }

  func stop() async throws -> URL {
    stopping = true
    do { try await stream.stopCapture() } catch {
      complete(.failure(error))
    }
    try await withCheckedThrowingContinuation { continuation in
      if let finished {
        continuation.resume(with: finished)
      } else {
        self.continuation = continuation
      }
    }
    return url
  }

  private func complete(_ result: Result<Void, Error>) {
    guard finished == nil else { return }
    finished = result
    continuation?.resume(with: result)
    continuation = nil
    if case .failure(let error) = result, !stopping { onFailure?(error) }
  }

  nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in self.complete(.success(())) }
  }
  nonisolated func recordingOutput(
    _ recordingOutput: SCRecordingOutput, didFailWithError error: Error
  ) {
    Task { @MainActor in self.complete(.failure(error)) }
  }
  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor in self.complete(.failure(error)) }
  }
}
