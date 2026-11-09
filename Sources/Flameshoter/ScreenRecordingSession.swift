// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit

@MainActor private final class RecordingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor final class ScreenRecordingSession: NSObject, NSWindowDelegate {
  private enum Phase {
    case ready, starting, recording, pausing, paused, finishing, preview, discarding
  }
  var onFinish: ((Bool) -> Void)?
  private let screen: NSScreen
  private let selection: CGRect
  private let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("Flameshoter-Recording-\(UUID().uuidString)", isDirectory: true)
  private let panel: RecordingPanel
  private let status = NSTextField(wrappingLabelWithString: "")
  private let rates = [5, 16, 24, 30, 60]
  private let delays = [0, 1, 2, 3, 5, 10]
  private var rate: ActionPopup!
  private var delay: ActionPopup!
  private var cursor: ActionCheck!
  private var systemAudio: ActionCheck!
  private var microphone: ActionCheck!
  private var startButton: ActionButton!
  private var pauseButton: ActionButton!
  private var stopButton: ActionButton!
  private var phase: Phase = .ready { didSet { refresh() } }
  private var segment: RecordingSegment?
  private var segments: [URL] = []
  private var preview: RecordingPreview?
  private var task: Task<Void, Never>?
  private var timer: Timer?
  private var startedAt: Date?
  private var elapsed: TimeInterval = 0
  private var cancelRequested = false
  private var closed = false

  var hasUnsavedRecording: Bool {
    switch phase {
    case .ready: return false
    case .preview: return preview?.hasUnsavedRecording ?? false
    default: return true
    }
  }

  init(screen: NSScreen, selection: CGRect) {
    self.screen = screen
    self.selection = selection
    panel = RecordingPanel(
      contentRect: CGRect(x: 0, y: 0, width: 420, height: 230),
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()
    panel.title = localized("Screen recording", "屏幕录制")
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
    rate = ActionPopup(items: rates.map { "\($0) FPS" }, selected: 2) { _ in }
    delay = ActionPopup(
      items: delays.map { $0 == 0 ? localized("No delay", "无延迟") : "\($0) s" }, selected: 0
    ) { _ in }
    cursor = ActionCheck(localized("Show cursor", "显示鼠标指针"), on: true) { _ in }
    systemAudio = ActionCheck(localized("System audio", "系统声音"), on: false) { [weak self] _ in
      self?.describeAudio()
    }
    microphone = ActionCheck(localized("Microphone", "麦克风"), on: false) { [weak self] _ in
      self?.describeAudio()
    }
    startButton = ActionButton(localized("Record", "开始录制"), symbol: "record.circle") {
      [weak self] in
      self?.start(resuming: false)
    }
    pauseButton = ActionButton(localized("Pause", "暂停")) { [weak self] in self?.pauseOrResume() }
    stopButton = ActionButton(localized("Stop", "停止")) { [weak self] in self?.stop() }
    let cancel = ActionButton(localized("Cancel", "取消")) { [weak self] in self?.requestClose() }
    status.textColor = .secondaryLabelColor
    status.stringValue = localized("Choose options, then start recording.", "选择录制选项，然后开始录制。")
    let options = stack(
      [
        label(localized("Frame rate", "帧率")), rate,
        label(localized("Delay", "延迟")), delay,
      ], vertical: false, spacing: 8)
    let toggles = stack([cursor, systemAudio, microphone], vertical: false, spacing: 12)
    let buttons = stack(
      [startButton, pauseButton, stopButton, cancel], vertical: false, spacing: 8)
    panel.contentView = padded(stack([options, toggles, status, buttons], spacing: 12), inset: 16)
    let screenSelection = CGRect(
      x: screen.frame.minX + selection.minX, y: screen.frame.maxY - selection.maxY,
      width: selection.width, height: selection.height)
    let visible = screen.visibleFrame
    let x =
      screenSelection.maxX + 12 + panel.frame.width <= visible.maxX
      ? screenSelection.maxX + 12 : screenSelection.minX - panel.frame.width - 12
    panel.setFrameOrigin(
      CGPoint(
        x: max(visible.minX, min(x, visible.maxX - panel.frame.width)),
        y: max(
          visible.minY,
          min(visible.maxY - panel.frame.height, screenSelection.maxY - panel.frame.height))))
    refresh()
  }

  func show() {
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }

  private func refresh() {
    guard startButton != nil else { return }
    let ready = phase == .ready
    for control in [rate, delay, cursor, systemAudio, microphone] as [NSControl] {
      control.isEnabled = ready
    }
    startButton.isEnabled = ready
    pauseButton.isEnabled = phase == .recording || phase == .paused
    pauseButton.title = phase == .paused ? localized("Resume", "继续") : localized("Pause", "暂停")
    stopButton.isEnabled = phase == .recording || phase == .paused
  }

  private func describeAudio() {
    guard phase == .ready else { return }
    if #unavailable(macOS 27), systemAudio.state == .on, microphone.state == .on {
      status.stringValue = localized(
        "On macOS 26, system and microphone audio share one track.",
        "在 macOS 26 上，系统声音和麦克风会合并为一条音轨。")
    } else {
      status.stringValue = localized("Choose options, then start recording.", "选择录制选项，然后开始录制。")
    }
  }

  private func start(resuming: Bool) {
    guard phase == (resuming ? .paused : .ready) else { return }
    phase = .starting
    cancelRequested = false
    let options = RecordingOptions(
      framesPerSecond: rates[rate.indexOfSelectedItem], showsCursor: cursor.state == .on,
      systemAudio: systemAudio.state == .on, microphone: microphone.state == .on)
    let countdown = resuming ? 0 : delays[delay.indexOfSelectedItem]
    task = Task {
      do {
        if options.microphone {
          guard AVCaptureDevice.default(for: .audio) != nil,
            await AVCaptureDevice.requestAccess(for: .audio)
          else { throw RecordingError.microphonePermission }
        }
        for remaining in stride(from: countdown, through: 1, by: -1) {
          status.stringValue = localized("Starting in \(remaining)…", "\(remaining) 秒后开始录制…")
          try await Task.sleep(for: .seconds(1))
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        status.stringValue = localized("Starting recording…", "正在开始录制…")
        let url = folder.appendingPathComponent("segment-\(UUID().uuidString).mp4")
        let current = try await RecordingSegment.start(
          screen: screen, selection: selection, options: options, url: url)
        if Task.isCancelled || cancelRequested {
          _ = try? await current.stop()
          finish()
          return
        }
        segment = current
        current.onFailure = { [weak owner = self] error in owner?.recordingFailed(error) }
        startedAt = Date()
        phase = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
          [weak owner = self] _ in
          Task { @MainActor in owner?.updateTime() }
        }
        updateTime()
      } catch {
        if cancelRequested || error is CancellationError {
          finish()
          return
        }
        showError(error)
        phase = resuming ? .paused : .ready
      }
      task = nil
    }
  }

  private func updateTime() {
    let seconds = Int(elapsed + (startedAt.map { Date().timeIntervalSince($0) } ?? 0))
    status.stringValue =
      localized("Recording", "正在录制") + String(format: "  %02d:%02d", seconds / 60, seconds % 60)
  }

  private func pauseOrResume() {
    if phase == .paused {
      start(resuming: true)
      return
    }
    guard phase == .recording else { return }
    phase = .pausing
    task = Task {
      do {
        try await endSegment()
        status.stringValue = localized("Paused", "已暂停")
        phase = .paused
      } catch { recover(error) }
      task = nil
    }
  }

  private func stop() {
    guard phase == .recording || phase == .paused else { return }
    let wasRecording = phase == .recording
    phase = .finishing
    status.stringValue = localized("Preparing recording…", "正在准备录屏…")
    task = Task {
      do {
        if wasRecording { try await endSegment() }
        let movie = try await RecordingMovie.combine(
          segments, into: folder.appendingPathComponent("recording-\(UUID().uuidString).mp4"))
        let controller = RecordingPreview(
          movie: movie, framesPerSecond: rates[rate.indexOfSelectedItem])
        preview = controller
        controller.onClose = { [weak owner = self] in owner?.finish() }
        panel.orderOut(nil)
        phase = .preview
        controller.show()
      } catch { recover(error) }
      task = nil
    }
  }

  private func endSegment() async throws {
    timer?.invalidate()
    timer = nil
    if let startedAt { elapsed += Date().timeIntervalSince(startedAt) }
    startedAt = nil
    guard let current = segment else { throw RecordingError.empty }
    segment = nil
    segments.append(try await current.stop())
  }

  private func recordingFailed(_ error: Error) {
    guard phase == .recording else { return }
    phase = .finishing
    task = Task {
      if let current = segment { _ = try? await current.stop() }
      segment = nil
      timer?.invalidate()
      timer = nil
      startedAt = nil
      recover(error)
      task = nil
    }
  }
  private func recover(_ error: Error) {
    showError(error)
    phase = segments.isEmpty ? .ready : .paused
  }
  private func showError(_ error: Error) {
    let message: String
    if case RecordingError.microphonePermission = error {
      message = localized(
        "Allow microphone access in System Settings to record microphone audio.",
        "请在系统设置中允许 Flameshoter 使用麦克风。")
    } else {
      message = errorMessage(error)
    }
    status.stringValue = localized("Recording failed", "录制失败")
    warning(localized("Unable to record screen", "无法录制屏幕"), message, window: panel)
  }

  private func requestClose() {
    guard phase != .pausing && phase != .finishing && phase != .discarding else { return }
    if phase == .recording || phase == .paused || (phase == .starting && !segments.isEmpty) {
      let alert = NSAlert()
      alert.messageText = localized("Discard this recording?", "要丢弃这段录屏吗？")
      alert.informativeText = localized("The recording has not been saved.", "录屏尚未保存。")
      alert.addButton(withTitle: localized("Keep recording", "保留录屏"))
      alert.addButton(withTitle: localized("Discard", "丢弃"))
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    if phase == .starting {
      cancelRequested = true
      task?.cancel()
      return
    }
    phase = .discarding
    task = Task {
      if let current = segment { _ = try? await current.stop() }
      segment = nil
      finish()
    }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    requestClose()
    return false
  }

  private func finish() {
    guard !closed else { return }
    closed = true
    timer?.invalidate()
    timer = nil
    panel.delegate = nil
    panel.close()
    try? FileManager.default.removeItem(at: folder)
    onFinish?(preview?.isSaved ?? false)
  }
  func invalidate() {
    task?.cancel()
    timer?.invalidate()
    panel.delegate = nil
    panel.close()
  }
}
