// SPDX-License-Identifier: GPL-3.0-or-later
import AVKit
import AppKit
import UniformTypeIdentifiers

@MainActor final class RecordingPreview: NSObject, NSWindowDelegate {
  var onClose: (() -> Void)?
  private let movie: URL
  private let window: NSWindow
  private let playerView = AVPlayerView()
  private let item: AVPlayerItem
  private let framesPerSecond: Int
  private let status = NSTextField(labelWithString: "")
  private var format: ActionPopup!
  private var trimButton: ActionButton!
  private var saveButton: ActionButton!
  private var cancelButton: ActionButton!
  private var exportTask: Task<Void, Error>?
  private var saved = false
  private var saving = false
  var isSaved: Bool { saved }
  var hasUnsavedRecording: Bool { !saved || saving }

  init(movie: URL, framesPerSecond: Int) {
    self.movie = movie
    self.framesPerSecond = framesPerSecond
    item = AVPlayerItem(url: movie)
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init()
    window.title = localized("Screen recording preview", "屏幕录制预览")
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 480, height: 350)
    window.delegate = self
    playerView.player = AVPlayer(playerItem: item)
    playerView.controlsStyle = .floating
    playerView.translatesAutoresizingMaskIntoConstraints = false
    format = ActionPopup(items: RecordingFormat.allCases.map(\.title), selected: 0) {
      [weak self] index in
      self?.status.stringValue =
        index == 0 ? "" : localized("GIF and WebP contain no audio.", "GIF 和 WebP 不包含声音。")
    }
    trimButton = ActionButton(localized("Trim", "修剪")) { [weak self] in self?.trim() }
    saveButton = ActionButton(localized("Save…", "保存…")) { [weak self] in self?.save() }
    cancelButton = ActionButton(localized("Cancel export", "取消导出")) { [weak self] in
      self?.exportTask?.cancel()
      self?.status.stringValue = localized("Cancelling…", "正在取消…")
    }
    cancelButton.isHidden = true
    status.textColor = .secondaryLabelColor
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let controls = stack(
      [trimButton, format, saveButton, cancelButton, status, NSView()], vertical: false)
    let content = NSView()
    content.addSubview(playerView)
    content.addSubview(controls)
    NSLayoutConstraint.activate([
      playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      playerView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      playerView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
      controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
    window.contentView = content
  }

  func show() {
    window.center()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }
  private func trim() {
    guard playerView.canBeginTrimming else {
      status.stringValue = localized("Wait for the recording to load.", "请等待录制视频载入。")
      return
    }
    playerView.beginTrimming { [weak self] result in
      Task { @MainActor in
        if result == .okButton {
          self?.saved = false
          self?.status.stringValue = localized("Changes not saved", "更改尚未保存")
        }
      }
    }
  }
  private func save() {
    guard !saving else { return }
    let selected = RecordingFormat.allCases[format.indexOfSelectedItem]
    let panel = NSSavePanel()
    panel.title = localized("Save screen recording", "保存屏幕录制")
    panel.allowedContentTypes = [selected.type]
    let date = DateFormatter()
    date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    panel.nameFieldStringValue =
      "Flameshoter_\(date.string(from: Date())).\(selected.fileExtension)"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    saving = true
    trimButton.isEnabled = false
    saveButton.isEnabled = false
    format.isEnabled = false
    cancelButton.isHidden = false
    status.stringValue = localized("Saving…", "正在保存…")
    Task {
      let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".flameshoter-\(UUID().uuidString).\(selected.fileExtension)")
      defer {
        try? FileManager.default.removeItem(at: temporary)
        saving = false
        trimButton.isEnabled = true
        saveButton.isEnabled = true
        format.isEnabled = true
        cancelButton.isHidden = true
        exportTask = nil
      }
      do {
        let start = item.reversePlaybackEndTime
        let end = item.forwardPlaybackEndTime
        let source = movie
        let fps = framesPerSecond
        let report: @MainActor @Sendable (Int) -> Void = { [weak owner = self] percent in
          if owner?.saving == true {
            owner?.status.stringValue = localized("Exporting", "正在导出") + " \(percent)%"
          }
        }
        let worker = Task.detached(priority: .userInitiated) {
          try await RecordingExport.write(
            movie: source, to: temporary, format: selected, from: start, to: end,
            framesPerSecond: fps
          ) { progress in
            let percent = Int(progress * 100)
            if percent % 5 == 0 { Task { @MainActor in report(percent) } }
          }
        }
        exportTask = worker
        try await worker.value
        try RecordingExport.install(temporary, at: destination)
        saved = true
        status.stringValue = localized("Saved", "已保存")
      } catch is CancellationError {
        status.stringValue = localized("Export cancelled", "已取消导出")
      } catch {
        status.stringValue = localized("Save failed", "保存失败")
        warning(
          localized("Unable to save recording", "无法保存录屏"), errorMessage(error), window: window)
      }
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if saving { return false }
    if !saved {
      let alert = NSAlert()
      alert.messageText = localized("Discard this recording?", "要丢弃这段录屏吗？")
      alert.informativeText = localized("The recording has not been saved.", "录屏尚未保存。")
      alert.addButton(withTitle: localized("Keep recording", "保留录屏"))
      alert.addButton(withTitle: localized("Discard", "丢弃"))
      if alert.runModal() != .alertSecondButtonReturn { return false }
    }
    return true
  }
  func windowWillClose(_ notification: Notification) {
    playerView.player?.pause()
    onClose?()
  }
}
