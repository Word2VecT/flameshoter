// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore
import ImageIO
import UniformTypeIdentifiers

@MainActor enum Files {
  static var supportedFormats: [(String, String, UTType)] {
    let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    return [
      ("png", "PNG", UTType.png), ("jpeg", "JPEG", .jpeg), ("tiff", "TIFF", .tiff),
      ("bmp", "BMP", .bmp), ("webp", "WebP", .webP),
    ].filter { supported.contains($0.2.identifier) }
  }
  static func save(
    _ image: CGImage, path: String? = nil, filename: String? = nil, forceDialog: Bool = false
  ) throws -> URL? {
    let preferences = Environment.shared.preferences
    var format = preferences.string("saveAsFileExtension")
    if format == "jpg" { format = "jpeg" }
    if !supportedFormats.contains(where: { $0.0 == format }) { format = "png" }
    let name = FilenamePattern.render(filename ?? preferences.string("filenamePattern"))
    let url: URL
    if let path {
      let requested = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      var directory: ObjCBool = false
      if FileManager.default.fileExists(atPath: requested.path, isDirectory: &directory),
        directory.boolValue || requested.hasDirectoryPath
      {
        url = uniqueFile(in: requested, name: name, format: format)
      } else if requested.pathExtension.isEmpty {
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        url = uniqueFile(in: requested, name: name, format: format)
      } else {
        url = requested
        format = requested.pathExtension.lowercased()
      }
    } else if preferences.bool("savePathFixed") && !forceDialog {
      url = uniqueFile(in: preferences.saveDirectory, name: name, format: format)
    } else {
      let panel = NSSavePanel()
      panel.title = localized("Save screenshot", "保存屏幕截图")
      panel.directoryURL = preferences.saveDirectory
      panel.nameFieldStringValue = name + "." + format
      panel.canCreateDirectories = true
      let formats = supportedFormats
      let popup = ActionPopup(
        items: formats.map(\.1), selected: formats.firstIndex(where: { $0.0 == format }) ?? 0
      ) { index in
        format = formats[index].0
        panel.allowedContentTypes = [formats[index].2]
        let old = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = old + "." + format
      }
      panel.accessoryView = padded(
        stack([label(localized("Image format", "图片格式")), popup], vertical: false), inset: 8)
      panel.allowedContentTypes = [formats[formats.firstIndex(where: { $0.0 == format }) ?? 0].2]
      guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
      url = chosen
    }
    let data = try ImageRenderer.data(
      image, format: format, quality: preferences.integer("jpegQuality"))
    try data.write(to: url, options: .atomic)
    Environment.shared.settings.set("savePath", url.deletingLastPathComponent().path)
    if preferences.bool("copyPathAfterSave") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.path, forType: .string)
    }
    return url
  }
  private static func uniqueFile(in directory: URL, name: String, format: String) -> URL {
    var result = directory.appendingPathComponent(name).appendingPathExtension(format)
    var n = 1
    while FileManager.default.fileExists(atPath: result.path) {
      result = directory.appendingPathComponent(name + "-\(n)").appendingPathExtension(format)
      n += 1
    }
    return result
  }
  static func openWith(_ image: CGImage) throws -> Bool {
    let panel = NSOpenPanel()
    panel.title = localized("Open capture with an application", "使用其他应用打开截图")
    panel.prompt = localized("Open", "打开")
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    var file: URL?
    repeat {
      guard panel.runModal() == .OK, let app = panel.url else { return file != nil }
      if file == nil {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
          "flameshoter-\(UUID().uuidString).png")
        try ImageRenderer.data(image).write(to: url, options: .atomic)
        file = url
      }
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open([file!], withApplicationAt: app, configuration: configuration) {
        _, error in
        if let error {
          Task { @MainActor in
            warning(localized("Unable to open capture", "无法打开截图"), errorMessage(error))
          }
        }
      }
    } while Environment.shared.preferences.bool("keepOpenAppLauncher")
    return true
  }
}
