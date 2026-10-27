// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ScreenCaptureKit

@MainActor struct CapturedScreen {
  let image: CGImage
  let screen: NSScreen
  var logicalSize: CGSize { screen.frame.size }
}

@MainActor enum CaptureService {
  static func combined(_ frames: [CapturedScreen]) throws -> (CGImage, CGSize) {
    guard let first = frames.first else { throw CaptureError.display }
    if frames.count == 1 { return (first.image, first.logicalSize) }
    let union = frames.dropFirst().reduce(first.screen.frame) { $0.union($1.screen.frame) }
    let scale = frames.map { $0.screen.backingScaleFactor }.max()!
    let width = Int((union.width * scale).rounded())
    let height = Int((union.height * scale).rounded())
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ImageError.renderFailed }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for frame in frames {
      let r = frame.screen.frame.offsetBy(dx: -union.minX, dy: -union.minY)
      context.draw(
        frame.image,
        in: CGRect(
          x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale))
    }
    guard let image = context.makeImage() else { throw ImageError.renderFailed }
    return (image, union.size)
  }
  static func capture(displayIndex: Int? = nil, fixture: URL? = nil) async throws
    -> [CapturedScreen]
  {
    let screens = NSScreen.screens
    if let fixture = fixture
      ?? ProcessInfo.processInfo.environment["FLAMESHOTER_TEST_IMAGE"].map({
        URL(fileURLWithPath: $0)
      })
    {
      guard let source = NSImage(contentsOf: fixture), let screen = screens.first else {
        throw ImageError.renderFailed
      }
      // Fixtures use native image drawing too, without requesting access to the real desktop.
      let scale = screen.backingScaleFactor
      let size = screen.frame.size
      let width = Int(size.width * scale)
      let height = Int(size.height * scale)
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { throw ImageError.renderFailed }
      let fit = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
      context.interpolationQuality = .high
      context.draw(
        image,
        in: CGRect(
          x: (CGFloat(width) - CGFloat(image.width) * fit) / 2,
          y: (CGFloat(height) - CGFloat(image.height) * fit) / 2, width: CGFloat(image.width) * fit,
          height: CGFloat(image.height) * fit))
      guard let output = context.makeImage() else { throw ImageError.renderFailed }
      return [CapturedScreen(image: output, screen: screen)]
    }
    guard Permissions.ensureScreenCapture() else { throw CaptureError.permission }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let ownApps = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let chosen =
      displayIndex.map { n in screens.indices.contains(n) ? [screens[n]] : [] } ?? screens
    guard !chosen.isEmpty else { throw CaptureError.display }
    var result: [CapturedScreen] = []
    for screen in chosen {
      guard
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
        let display = content.displays.first(where: { $0.displayID == id.uint32Value })
      else { continue }
      let filter = SCContentFilter(
        display: display, excludingApplications: ownApps, exceptingWindows: [])
      let configuration = SCScreenshotConfiguration()
      configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
      configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
      configuration.showsCursor = false
      configuration.dynamicRange = .sdr
      configuration.displayIntent = .local
      let output = try await SCScreenshotManager.captureScreenshot(
        contentFilter: filter, configuration: configuration)
      guard let image = output.sdrImage else { throw ImageError.renderFailed }
      result.append(CapturedScreen(image: image, screen: screen))
    }
    guard !result.isEmpty else { throw CaptureError.display }
    return result
  }
}

enum CaptureError: LocalizedError {
  case permission, display
  var errorDescription: String? {
    switch self {
    case .permission: return "Screen Recording access is required."
    case .display: return "The selected display is unavailable."
    }
  }
}

@MainActor enum Permissions {
  static func openSettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }
  static func ensureScreenCapture() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    if CGRequestScreenCaptureAccess(), CGPreflightScreenCaptureAccess() { return true }
    let alert = NSAlert()
    alert.messageText = localized("Allow Screen Recording to take screenshots", "允许屏幕录制以使用截图功能")
    alert.informativeText = localized(
      "Enable Flameshoter in System Settings, then restart the app. If it is absent, add Flameshoter from Applications. An update using the same fixed certificate should retain this authorization.",
      "请在系统设置中允许 Flameshoter，然后重新启动。若列表中没有此应用，请点击 + 添加“应用程序”中的 Flameshoter。同一固定证书签署的更新会保持应用身份。")
    for title in [
      localized("Open System Settings", "打开系统设置"), localized("Restart", "重新启动"),
      localized("Repair authorization…", "修复授权…"), localized("Later", "稍后"),
    ] { alert.addButton(withTitle: title) }
    switch alert.runModal() {
    case .alertFirstButtonReturn: openSettings()
    case .alertSecondButtonReturn: restart()
    case .alertThirdButtonReturn: repair()
    default: break
    }
    return false
  }
  static func restart() {
    guard (NSApp.delegate as? AppController)?.prepareForRestart() ?? true else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = [
      "-c",
      "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n -a \"$2\"",
      "flameshoter-restart", String(ProcessInfo.processInfo.processIdentifier),
      Bundle.main.bundlePath,
    ]
    do {
      try task.run()
      NSApp.terminate(nil)
    } catch { warning(localized("Unable to restart", "无法重新启动"), errorMessage(error)) }
  }
  static func repair() {
    let alert = NSAlert()
    alert.messageText = localized("Register Screen Recording again?", "重新登记屏幕录制授权？")
    alert.informativeText = localized(
      "This resets only Flameshoter’s Screen Recording entry. Grant access again after restarting. Use this only if the enabled permission is not working.",
      "这只会清除 Flameshoter 的录屏记录，重启后需要重新允许。仅在系统开关已开启但截图仍失败时使用。")
    alert.addButton(withTitle: localized("Cancel", "取消"))
    alert.addButton(withTitle: localized("Repair and restart", "修复并重新启动"))
    guard alert.runModal() == .alertSecondButtonReturn,
      Bundle.main.bundleIdentifier == "io.github.Word2VecT.flameshoter"
    else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    task.arguments = ["reset", "ScreenCapture", "io.github.Word2VecT.flameshoter"]
    do {
      try task.run()
      task.waitUntilExit()
      if task.terminationStatus == 0 {
        restart()
      } else {
        warning(
          localized("Repair failed", "修复失败"),
          localized(
            "Remove and add Flameshoter in Screen Recording settings.",
            "请在屏幕录制设置中移除并重新添加 Flameshoter。"))
      }
    } catch { warning(localized("Repair failed", "修复失败"), errorMessage(error)) }
  }
}
