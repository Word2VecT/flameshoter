// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

public struct Preferences: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var values: [String: String] = [:]
  public var shortcuts = Shortcut.defaults
  public var unassignedShortcuts: Set<String> = []
  public var colors = RGBA.defaults
  public var tools = Tool.defaultToolbar
  public init() {}
  public static let defaults: [String: String] = [
    "uiLanguage": "auto", "startupLaunch": "false", "disabledTrayIcon": "false",
    "showStartupLaunchMessage": "false", "autoCloseIdleDaemon": "false",
    "allowMultipleGuiInstances": "false", "showDesktopNotification": "false",
    "showAbortNotification": "false", "showHelp": "true", "showQuitPrompt": "true",
    "saveLastRegion": "true", "copyOnDoubleClick": "false", "showMagnifier": "false",
    "squareMagnifier": "false", "showSidePanelButton": "true", "useNativeFullscreen": "false",
    "showSelectionGeometry": "4", "showSelectionGeometryHideTime": "3000", "undoLimit": "100",
    "antialiasingPinZoom": "true", "useSystemAccentColor": "true", "uiColor": "#007aff",
    "contrastUiColor": "#194678", "drawColor": "#ff3b30", "contrastOpacity": "190",
    "predefinedColorPaletteLarge": "false", "savePath": "", "savePathFixed": "false",
    "filenamePattern": "%F_%H-%M-%S", "saveAsFileExtension": "png", "jpegQuality": "75",
    "saveAfterCopy": "false", "copyPathAfterSave": "false", "useJpgForClipboard": "false",
    "keepOpenAppLauncher": "false", "drawThickness": "3", "drawRectangleSize": "2",
    "drawMarkerSize": "16", "drawFontSize": "24", "drawCircleCounterSize": "28",
    "drawPixelateSize": "12", "fontFamily": "", "drawCircleCounterOutline": "true",
    "reverseArrow": "false", "arrowStyle": "0", "insecurePixelate": "false", "lastRegion": "",
    "filledShapes": "false", "textBold": "false", "textItalic": "false", "textUnderline": "false",
    "textStrike": "false", "textAlignment": "0",
  ]
  public func string(_ key: String) -> String { values[key] ?? Self.defaults[key] ?? "" }
  public func bool(_ key: String) -> Bool {
    ["true", "1", "yes"].contains(string(key).lowercased())
  }
  public func integer(_ key: String) -> Int {
    Int(string(key)) ?? Int(Self.defaults[key] ?? "") ?? 0
  }
  public func color(_ key: String) -> RGBA { RGBA(hex: string(key)) ?? .red }
  public var chinese: Bool {
    string("uiLanguage").hasPrefix("zh")
      || (string("uiLanguage") == "auto"
        && (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false))
  }
  public func shortcut(_ key: String) -> Shortcut? {
    unassignedShortcuts.contains(key) ? nil : shortcuts[key]
  }
  public var saveDirectory: URL {
    let path = string("savePath")
    return path.isEmpty
      ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
      : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
  }
  public func toolSize(_ tool: Tool) -> CGFloat { CGFloat(max(1, integer(tool.sizeKey))) }
}

public enum SettingsError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let key): return "Invalid configuration: \(key)"
    }
  }
}

public final class SettingsStore {
  public private(set) var preferences: Preferences
  public let url: URL
  public private(set) var loadError: Error?
  public var onChange: (() -> Void)?
  public init(url: URL, legacyURLs: [URL] = []) {
    self.url = url
    preferences = Preferences()
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        try Self.validate(preferences)
      } catch {
        loadError = error
        preferences = Preferences()
      }
    } else if let legacy = legacyURLs.first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) {
      do {
        preferences = try Self.parseINI(String(contentsOf: legacy, encoding: .utf8))
        try save()
      } catch { loadError = error }
    }
  }
  public func update(_ body: (inout Preferences) -> Void) {
    body(&preferences)
    do {
      try save()
      loadError = nil
    } catch { loadError = error }
    onChange?()
  }
  public func set(_ key: String, _ value: String) { update { $0.values[key] = value } }
  public func set(_ key: String, _ value: Bool) { set(key, value ? "true" : "false") }
  public func set(_ key: String, _ value: Int) { set(key, String(value)) }
  public func reset() { update { $0 = Preferences() } }
  public func save() throws {
    try Self.validate(preferences)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(preferences).write(to: url, options: .atomic)
  }
  public func importFile(_ file: URL) throws {
    let data = try Data(contentsOf: file)
    let imported =
      file.pathExtension.lowercased() == "json"
      ? try JSONDecoder().decode(Preferences.self, from: data)
      : try Self.parseINI(String(decoding: data, as: UTF8.self))
    try Self.validate(imported)
    preferences = imported
    try save()
    onChange?()
  }
  public func exportFile(_ file: URL) throws {
    if file.pathExtension.lowercased() == "ini" {
      var lines = ["[Native]", "schemaVersion=1", "", "[General]"]
      for (key, value) in Preferences.defaults.merging(preferences.values, uniquingKeysWith: { $1 })
        .sorted(by: { $0.key < $1.key })
      { lines.append("\(key)=\(value)") }
      lines += [
        "buttons=" + preferences.tools.map { String($0.rawValue) }.joined(separator: ","),
        "userColors=" + preferences.colors.map(\.hex).joined(separator: ","), "", "[Shortcuts]",
      ]
      for key in Shortcut.defaults.keys.sorted() {
        lines.append("\(key)=\(preferences.shortcut(key)?.portable ?? "")")
      }
      try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    } else {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(preferences).write(to: file, options: .atomic)
    }
  }
  public static func parseINI(_ content: String) throws -> Preferences {
    var result = Preferences()
    var group = "General"
    var recognized = false
    let native = content.contains("[Native]")
    for raw in content.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
      if line.hasPrefix("["), line.hasSuffix("]") {
        group = String(line.dropFirst().dropLast())
        continue
      }
      guard let equal = line.firstIndex(of: "=") else { throw SettingsError.invalid(line) }
      let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\"") {
        value = String(value.dropFirst().dropLast())
      }
      if group == "General" {
        if Preferences.defaults[key] != nil {
          // The Qt font-size option stored an 8-point display offset.
          if !native, key == "drawFontSize", let size = Int(value) { value = String(size + 8) }
          if key == "saveAsFileExtension", value.isEmpty { value = "png" }
          result.values[key] = value
          recognized = true
        } else if key == "buttons", !value.hasPrefix("@") {
          result.tools = value.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces)).flatMap(Tool.init(rawValue:))
          }
          recognized = true
        } else if key == "userColors" {
          let palette = value.split(separator: ",").compactMap { RGBA(hex: String($0)) }
          if palette.count >= 3 {
            result.colors = palette
            recognized = true
          }
        }
      } else if group == "Shortcuts", Shortcut.defaults[key] != nil {
        if value.isEmpty {
          result.unassignedShortcuts.insert(key)
        } else if let shortcut = Shortcut(portable: value) {
          result.shortcuts[key] = shortcut
        } else {
          throw SettingsError.invalid(key)
        }
        recognized = true
      }
    }
    guard recognized else { throw SettingsError.invalid("empty file") }
    try validate(result)
    return result
  }
  public static func validate(_ p: Preferences) throws {
    let ranges = [
      "contrastOpacity": 0...255, "undoLimit": 0...999, "jpegQuality": 0...100,
      "showSelectionGeometry": 0...5, "showSelectionGeometryHideTime": 0...60000,
      "drawThickness": 1...500, "drawRectangleSize": 1...500, "drawMarkerSize": 1...500,
      "drawFontSize": 1...500, "drawCircleCounterSize": 1...500, "drawPixelateSize": 1...500,
      "arrowStyle": 0...1, "textAlignment": 0...2,
    ]
    for (key, range) in ranges {
      guard let n = Int(p.string(key)), range.contains(n) else { throw SettingsError.invalid(key) }
    }
    guard ["auto", "en", "zh_CN", "zh-Hans"].contains(p.string("uiLanguage")) else {
      throw SettingsError.invalid("uiLanguage")
    }
    guard ["png", "jpg", "jpeg", "webp", "tiff", "bmp"].contains(p.string("saveAsFileExtension"))
    else { throw SettingsError.invalid("saveAsFileExtension") }
    guard (3...17).contains(p.colors.count) else { throw SettingsError.invalid("colors") }
    for color in p.colors + [p.color("drawColor")] {
      guard
        [color.red, color.green, color.blue, color.alpha].allSatisfy({
          $0.isFinite && (0...1).contains($0)
        })
      else { throw SettingsError.invalid("color") }
    }
  }
}
