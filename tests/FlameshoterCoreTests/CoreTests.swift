// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import FlameshoterCore

private func fixture(_ width: Int = 24, _ height: Int = 20, interior: RGBA? = nil) -> CGImage {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray: 0.6, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: height - 3, width: width, height: 3))
  if let interior {
    context.setFillColor(interior.cgColor)
    context.fill(CGRect(x: 4, y: 4, width: width - 8, height: height - 8))
  }
  return context.makeImage()!
}
private func pixels(_ image: CGImage) -> [UInt8] {
  let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Array(
    UnsafeBufferPointer(
      start: context.data!.assumingMemoryBound(to: UInt8.self),
      count: image.width * image.height * 4))
}

@Test @MainActor func cropPreservesPixelsAndCorners() throws {
  let source = fixture()
  var document = CaptureDocument(image: source, logicalSize: CGSize(width: 12, height: 10))
  document.selection = CGRect(x: 1, y: 1, width: 7, height: 5)
  let actual = try ImageRenderer.render(document)
  #expect(actual.width == 14)
  #expect(actual.height == 10)
  #expect(pixels(actual) == pixels(source.cropping(to: CGRect(x: 2, y: 2, width: 14, height: 10))!))
}
@Test @MainActor func unselectedCapturePreservesWholeImage() throws {
  let source = fixture()
  let document = CaptureDocument(image: fixture(), logicalSize: CGSize(width: 24, height: 20))
  #expect(pixels(try ImageRenderer.render(document)) == pixels(source))
}
@Test @MainActor func annotationCoordinatesAreNotInverted() throws {
  var document = CaptureDocument(image: fixture(), logicalSize: CGSize(width: 24, height: 20))
  document.add(
    Annotation(
      tool: .line, points: [CGPoint(x: 5, y: 5), CGPoint(x: 18, y: 5)], color: RGBA(0, 0, 1),
      width: 2))
  let image = try ImageRenderer.render(document)
  let data = pixels(image)
  #expect(data[(5 * image.width + 10) * 4 + 2] > 200)
  #expect(data[(14 * image.width + 10) * 4 + 2] < 200)
}
@Test @MainActor func redactionDoesNotDependOnInteriorPixels() throws {
  var red = CaptureDocument(
    image: fixture(interior: RGBA(1, 0, 0)), logicalSize: CGSize(width: 24, height: 20))
  var blue = CaptureDocument(
    image: fixture(interior: RGBA(0, 0, 1)), logicalSize: CGSize(width: 24, height: 20))
  var mask = Annotation(
    tool: .pixelate, points: [CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 16)], width: 4)
  mask.traditionalPixelation = false
  red.add(mask)
  blue.add(mask)
  #expect(pixels(try ImageRenderer.render(red)) == pixels(try ImageRenderer.render(blue)))
}
@Test func historyAndHitTesting() {
  var document = CaptureDocument(
    image: fixture(), logicalSize: CGSize(width: 24, height: 20), undoLimit: 2)
  let line = Annotation(tool: .line, points: [CGPoint(x: 2, y: 2), CGPoint(x: 20, y: 2)], width: 2)
  document.add(line)
  document.add(Annotation(tool: .rectangle, points: [CGPoint(x: 4, y: 4), CGPoint(x: 10, y: 10)]))
  #expect(document.annotations.count == 2)
  document.undo()
  #expect(document.annotations == [line])
  document.redo()
  #expect(document.annotations.count == 2)
  #expect(line.hitTest(CGPoint(x: 12, y: 2)))
  #expect(!line.hitTest(CGPoint(x: 12, y: 18)))
}
@Test func legacyConfigurationAndShortcuts() throws {
  let p = try SettingsStore.parseINI(
    "[General]\nuiLanguage=zh_CN\nsavePath=/tmp/截图\ndrawFontSize=8\nsaveAsFileExtension=\ncontrastOpacity=150\n[Shortcuts]\nTAKE_SCREENSHOT=Ctrl+Shift+X\nTYPE_SAVE=\n"
  )
  #expect(p.chinese)
  #expect(p.string("savePath") == "/tmp/截图")
  #expect(p.integer("drawFontSize") == 16)
  #expect(p.string("saveAsFileExtension") == "png")
  #expect(p.shortcut("TYPE_SAVE") == nil)
  #expect(p.shortcut("TAKE_SCREENSHOT") == Shortcut(7, [.command, .shift]))
}
@Test func configurationRoundTripAndAtomicSave() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
  store.set("drawFontSize", 32)
  store.set("uiLanguage", "zh_CN")
  store.set("saveAfterCopy", true)
  try store.exportFile(root.appendingPathComponent("preferences.ini"))
  try store.importFile(root.appendingPathComponent("preferences.ini"))
  #expect(store.preferences.integer("drawFontSize") == 32)
  let reloaded = SettingsStore(url: store.url)
  #expect(reloaded.preferences == store.preferences)
  #expect(reloaded.preferences.bool("saveAfterCopy"))
}
@Test func invalidSettingsAreRejected() {
  #expect(throws: SettingsError.self) { try SettingsStore.parseINI("[General]\njpegQuality=150") }
  #expect(throws: SettingsError.self) { try SettingsStore.parseINI("[General]\nundoLimit=-10") }
  #expect(throws: SettingsError.self) { try SettingsStore.parseINI("not an ini file") }
}
@Test func shortcutPortableRoundTrip() {
  for shortcut in Shortcut.defaults.values {
    #expect(Shortcut(portable: shortcut.portable) == shortcut)
  }
  #expect(Shortcut(portable: "Meta+Alt+A") == Shortcut(0, [.control, .option]))
}
@Test func filenamePatternAndSafeFilename() {
  let date = Date(timeIntervalSince1970: 0)
  #expect(
    FilenamePattern.render("截图_%F_%H-%M-%S", date: date, timeZone: TimeZone(secondsFromGMT: 0)!)
      == "截图_1970-01-01_00-00-00")
  #expect(
    FilenamePattern.render("folder/name:%Y", date: date, timeZone: TimeZone(secondsFromGMT: 0)!)
      == "folder_name-1970")
}

@Test @MainActor func cropAfterAnnotationsUsesGlobalCoordinates() throws {
  let source = fixture()
  var full = CaptureDocument(image: source, logicalSize: CGSize(width: 24, height: 20))
  full.add(
    Annotation(
      tool: .rectangle, points: [CGPoint(x: 7, y: 6), CGPoint(x: 17, y: 15)], color: RGBA(0, 0, 1),
      width: 2))
  let reference = try ImageRenderer.render(full)
  full.selection = CGRect(x: 5, y: 4, width: 14, height: 13)
  let actual = try ImageRenderer.render(full)
  #expect(
    pixels(actual) == pixels(reference.cropping(to: CGRect(x: 5, y: 4, width: 14, height: 13))!))
}

@Test func shareToolUpgradePreservesPreferencesAndCanStayHidden() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 1
  old.tools = [.pencil, .copy]
  old.values["drawColor"] = "#123456"
  old.shortcuts["TYPE_COPY"] = Shortcut(8, [.command, .option])
  try JSONEncoder().encode(old).write(to: url)
  let upgraded = SettingsStore(url: url)
  #expect(upgraded.loadError == nil)
  #expect(upgraded.preferences.schemaVersion == 2)
  #expect(upgraded.preferences.tools == [.pencil, .copy, .share])
  #expect(upgraded.preferences.values == old.values)
  #expect(upgraded.preferences.shortcuts == old.shortcuts)
  upgraded.update {
    $0.tools.removeAll { $0 == .share }
    $0.shortcuts["TYPE_SHARE"] = Shortcut(1, [.command, .shift])
  }
  let reopened = SettingsStore(url: url)
  #expect(!reopened.preferences.tools.contains(.share))
  let ini = root.appendingPathComponent("export.ini")
  try reopened.exportFile(ini)
  let imported = try SettingsStore.parseINI(String(contentsOf: ini, encoding: .utf8))
  #expect(imported.shortcut("TYPE_SHARE") == Shortcut(1, [.command, .shift]))
  #expect(!imported.tools.contains(.share))
}

@Test func existingSettingsGainTheShareShortcutWithoutReplacingOverrides() {
  var preferences = Preferences()
  preferences.shortcuts.removeValue(forKey: "TYPE_SHARE")
  #expect(preferences.shortcut("TYPE_SHARE") == Shortcut(1, [.command, .shift]))
  let custom = Shortcut(1, [.command, .option])
  preferences.shortcuts["TYPE_SHARE"] = custom
  #expect(preferences.shortcut("TYPE_SHARE") == custom)
  preferences.unassignedShortcuts.insert("TYPE_SHARE")
  #expect(preferences.shortcut("TYPE_SHARE") == nil)
}
