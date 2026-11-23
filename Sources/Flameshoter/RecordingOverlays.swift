// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import Carbon.HIToolbox
import FlameshoterCore

// Only these windows are explicitly included in the recording filter. Other app UI stays excluded.
@MainActor final class RecordingOverlays {
  private var cameraSession: AVCaptureSession?
  private var cameraWindow: NSPanel?
  private var shortcutWindow: NSPanel?
  private let shortcutLabel = NSTextField(labelWithString: "")
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var clearTask: Task<Void, Never>?
  var windowIDs: Set<CGWindowID> {
    Set([cameraWindow, shortcutWindow].compactMap { $0 }.map { CGWindowID($0.windowNumber) })
  }

  static func shortcutLabel(for event: NSEvent) -> String? {
    guard event.type == .keyDown, !event.isARepeat, !IsSecureEventInputEnabled() else { return nil }
    let modifiers = event.modifierFlags.intersection(Shortcut.relevant)
    let isShortcut = !modifiers.intersection([.command, .control, .option]).isEmpty
    let navigation: Set<UInt16> = [36, 48, 51, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126]
    let functionKeys: Set<UInt16> = [96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122]
    guard isShortcut || navigation.contains(event.keyCode) || functionKeys.contains(event.keyCode),
      Shortcut.names[event.keyCode] != nil
    else { return nil }
    return Shortcut(event.keyCode, modifiers).display
  }

  static func start(screen: NSScreen, selection: CGRect, camera: Bool, shortcuts: Bool) async throws
    -> RecordingOverlays
  {
    let overlays = RecordingOverlays()
    do {
      if shortcuts {
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
          throw RecordingError.inputMonitoringPermission
        }
      }
      let area = CGRect(
        x: screen.frame.minX + selection.minX,
        y: screen.frame.maxY - selection.maxY, width: selection.width, height: selection.height)
      if camera {
        guard let device = AVCaptureDevice.default(for: .video) else {
          throw RecordingError.cameraUnavailable
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
          throw RecordingError.cameraPermission
        }
        try Task.checkCancellation()
        let session = AVCaptureSession()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.cameraUnavailable }
        session.addInput(input)
        overlays.cameraSession = session
        let size = CGSize(
          width: min(240, area.width * 0.3), height: min(240, area.width * 0.3) * 9 / 16)
        let margin = min(12, area.width * 0.02, area.height * 0.02)
        let window = makeWindow(
          rect: CGRect(
            x: area.maxX - size.width - margin,
            y: area.minY + margin, width: size.width, height: min(size.height, area.height * 0.4)))
        let view = NSView(frame: window.contentView!.bounds)
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer = preview
        window.contentView = view
        overlays.cameraWindow = window
        await Task.detached(priority: .userInitiated) { session.startRunning() }.value
        try Task.checkCancellation()
        window.orderFrontRegardless()
      }
      if shortcuts {
        let width = min(260, area.width * 0.65)
        let height = min(40, area.height * 0.2)
        let window = makeWindow(
          rect: CGRect(
            x: area.midX - width / 2,
            y: area.minY + min(12, area.height * 0.02), width: width, height: height))
        let label = overlays.shortcutLabel
        label.frame = window.contentView!.bounds
        label.autoresizingMask = [.width, .height]
        label.alignment = .center
        label.font = .systemFont(ofSize: max(10, min(20, height * 0.5)), weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.drawsBackground = true
        window.contentView = label
        overlays.shortcutWindow = window
        window.orderFrontRegardless()
        overlays.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
          [weak overlays] event in
          MainActor.assumeIsolated { overlays?.display(event) }
        }
        overlays.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
          [weak overlays] event in
          overlays?.display(event)
          return event
        }
      }
      return overlays
    } catch {
      await overlays.stop()
      throw error
    }
  }

  private static func makeWindow(rect: CGRect) -> NSPanel {
    let window = NSPanel(
      contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .floating
    window.hidesOnDeactivate = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    return window
  }

  private func display(_ event: NSEvent) {
    guard let text = Self.shortcutLabel(for: event) else { return }
    shortcutLabel.stringValue = text
    shortcutLabel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
    clearTask?.cancel()
    clearTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
      self?.shortcutLabel.stringValue = ""
      self?.shortcutLabel.backgroundColor = .clear
    }
  }

  func stop() async {
    clearTask?.cancel()
    clearTask = nil
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    cameraWindow?.close()
    shortcutWindow?.close()
    cameraWindow = nil
    shortcutWindow = nil
    if let session = cameraSession {
      cameraSession = nil
      await Task.detached { session.stopRunning() }.value
    }
  }
}
