// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

@MainActor final class Environment {
  static let shared = Environment()
  let settings: SettingsStore
  var preferences: Preferences { settings.preferences }
  init() {
    let variables = ProcessInfo.processInfo.environment
    let root: URL
    let legacy: [URL]
    if let path = variables["FLAMESHOTER_TEST_CONFIG"] {
      root = URL(fileURLWithPath: path, isDirectory: true)
      legacy = [root.appendingPathComponent("flameshoter/flameshoter.ini")]
    } else {
      root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Flameshoter", isDirectory: true)
      let home = FileManager.default.homeDirectoryForCurrentUser
      legacy = [
        home.appendingPathComponent(".config/flameshoter/flameshoter.ini"),
        home.appendingPathComponent("Library/Preferences/flameshoter/flameshoter.ini"),
      ]
    }
    settings = SettingsStore(url: root.appendingPathComponent("settings.json"), legacyURLs: legacy)
  }
}

@MainActor func localized(_ english: String, _ chinese: String) -> String {
  Environment.shared.preferences.chinese ? chinese : english
}
@MainActor func toolTitle(_ tool: Tool) -> String { localized(tool.title.0, tool.title.1) }

@MainActor final class ActionButton: NSButton {
  var invoke: (() -> Void)?
  convenience init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
    self.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    self.action = #selector(run)
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    invoke = action
  }
  @objc private func run() { invoke?() }
}
@MainActor final class ActionCheck: NSButton {
  var change: ((Bool) -> Void)?
  convenience init(_ title: String, on: Bool, change: @escaping (Bool) -> Void) {
    self.init(frame: .zero)
    setButtonType(.switch)
    self.title = title
    state = on ? .on : .off
    self.change = change
    target = self
    action = #selector(run)
  }
  @objc private func run() { change?(state == .on) }
}
@MainActor final class ActionPopup: NSPopUpButton {
  var change: ((Int) -> Void)?
  convenience init(items: [String], selected: Int, change: @escaping (Int) -> Void) {
    self.init(frame: .zero, pullsDown: false)
    addItems(withTitles: items)
    selectItem(at: max(0, min(selected, items.count - 1)))
    self.change = change
    target = self
    action = #selector(run)
  }
  @objc private func run() { change?(indexOfSelectedItem) }
}
@MainActor final class ActionField: NSTextField, NSTextFieldDelegate {
  var change: ((String) -> Void)?
  convenience init(_ text: String, change: @escaping (String) -> Void) {
    self.init(frame: .zero)
    stringValue = text
    self.change = change
    delegate = self
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }
  func controlTextDidEndEditing(_ obj: Notification) { change?(stringValue) }
}
@MainActor final class ActionColor: NSColorWell {
  var change: ((NSColor) -> Void)?
  convenience init(color: NSColor, change: @escaping (NSColor) -> Void) {
    self.init(frame: .zero)
    self.color = color
    self.change = change
    target = self
    action = #selector(run)
  }
  @objc private func run() { change?(color) }
}
@MainActor final class ActionSlider: NSSlider {
  var change: ((Double) -> Void)?
  convenience init(_ value: Double, min: Double, max: Double, change: @escaping (Double) -> Void) {
    self.init(value: value, minValue: min, maxValue: max, target: nil, action: nil)
    self.change = change
    target = self
    action = #selector(run)
  }
  @objc private func run() { change?(doubleValue) }
}
@MainActor class PassiveView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor final class PassiveGlass: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor final class PassiveFrost: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor func label(_ text: String, secondary: Bool = false, size: CGFloat? = nil) -> NSTextField
{
  let view = NSTextField(wrappingLabelWithString: text)
  view.textColor = secondary ? .secondaryLabelColor : .labelColor
  if let size { view.font = .systemFont(ofSize: size) }
  view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  view.setContentHuggingPriority(.defaultLow, for: .horizontal)
  return view
}
@MainActor func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12)
  -> NSStackView
{
  let s = NSStackView(views: views)
  s.orientation = vertical ? .vertical : .horizontal
  s.alignment = vertical ? .leading : .centerY
  s.spacing = spacing
  s.translatesAutoresizingMaskIntoConstraints = false
  return s
}
@MainActor func padded(_ view: NSView, inset: CGFloat = 12) -> NSView {
  let parent = NSView()
  view.translatesAutoresizingMaskIntoConstraints = false
  parent.addSubview(view)
  NSLayoutConstraint.activate([
    view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
    view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
    view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
    view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
  ])
  return parent
}
@MainActor func glass(_ view: NSView, interactive: Bool = true, radius: CGFloat = 24)
  -> NSGlassEffectView
{
  let result = NSGlassEffectView()
  result.style = .regular
  result.cornerRadius = radius
  let content = padded(view, inset: 8)
  result.contentView = content
  result.translatesAutoresizingMaskIntoConstraints = false
  let size = content.fittingSize
  result.widthAnchor.constraint(equalToConstant: size.width).isActive = true
  result.heightAnchor.constraint(equalToConstant: size.height).isActive = true
  if #available(macOS 27, *) { result.effectIsInteractive = interactive }
  return result
}
@MainActor func warning(_ title: String, _ detail: String, window: NSWindow? = nil) {
  let alert = NSAlert()
  alert.alertStyle = .warning
  alert.messageText = title
  alert.informativeText = detail
  alert.addButton(withTitle: localized("OK", "好"))
  if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
@MainActor func confirmDiscard(_ window: NSWindow? = nil) -> Bool {
  let alert = NSAlert()
  alert.messageText = localized("Discard this capture?", "丢弃这张截图？")
  alert.informativeText = localized("Unsaved annotations will be lost.", "未保存的标注将会丢失。")
  alert.addButton(withTitle: localized("Keep editing", "继续编辑"))
  alert.addButton(withTitle: localized("Discard", "丢弃"))
  return alert.runModal() == .alertSecondButtonReturn
}

@MainActor func errorMessage(_ error: Error) -> String {
  if let image = error as? ImageError {
    switch image {
    case .emptySelection: return localized("Select a capture region first.", "请先选择截图区域。")
    case .renderFailed: return localized("Unable to render this capture.", "无法绘制此截图。")
    case .unsupportedFormat:
      return localized("This image format is not supported by macOS.", "macOS 不支持导出此图片格式。")
    case .encodeFailed: return localized("Unable to encode the image.", "无法编码图片。")
    }
  }
  if case SettingsError.invalid(let key) = error {
    return localized("Invalid configuration: ", "配置无效：") + key
  }
  if let capture = error as? CaptureError {
    switch capture {
    case .permission: return localized("Screen Recording access is required.", "需要屏幕录制权限。")
    case .display: return localized("The selected display is unavailable.", "所选屏幕当前不可用。")
    }
  }
  return error.localizedDescription
}
