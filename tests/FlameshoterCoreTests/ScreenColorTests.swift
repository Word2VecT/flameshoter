// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
@testable import Flameshoter
@testable import FlameshoterCore

@Test func pixelColorSamplesTopLeftCoordinatesAndFormats() throws {
  let pixels: [UInt8] = [
    255, 0, 0, 255, 0, 255, 0, 255,
    0, 0, 255, 255, 4, 133, 247, 255,
  ]
  let image = try #require(CGImage(
    width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
    shouldInterpolate: false, intent: .defaultIntent))
  #expect(ScreenColor.sample(image, point: CGPoint(x: 0, y: 0), scale: 2)?.string(.hashHex) == "#ff0000")
  #expect(ScreenColor.sample(image, point: CGPoint(x: 0.5, y: 0), scale: 2)?.string(.hashHex) == "#00ff00")
  #expect(ScreenColor.sample(image, point: CGPoint(x: 0, y: 0.5), scale: 2)?.string(.hashHex) == "#0000ff")
  let color = try #require(ScreenColor.sample(image, point: CGPoint(x: 0.5, y: 0.5), scale: 2))
  #expect(color.string(.hashHex) == "#0485f7")
  #expect(color.string(.hex) == "0485f7")
  #expect(color.string(.rgb) == "rgb(4, 133, 247)")
  #expect(color.string(.bgr) == "bgr(247, 133, 4)")
  #expect(color.string(.hsv) == "hsv(208, 98%, 97%)")
  #expect(color.string(.hsl) == "hsl(208, 97%, 49%)")
  for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.5)] {
    let preview = try #require(ScreenColor.neighborhood(image, point: point, scale: 2))
    #expect(ScreenColor.sample(preview, point: CGPoint(x: 8, y: 8), scale: 1)
      == ScreenColor.sample(image, point: point, scale: 2))
  }
  #expect(ScreenColor.sample(image, point: CGPoint(x: -1, y: 0), scale: 2) == nil)
  #expect(ScreenColor.sample(image, point: CGPoint(x: 1, y: 1), scale: 2) == nil)
}

@Test func pixelColorShortcutMigrationPreservesExistingBindings() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 3
  old.shortcuts.removeValue(forKey: "TYPE_COPY_PIXEL_COLOR")
  old.shortcuts["TYPE_COPY"] = Shortcut(8, [.option])
  try JSONEncoder().encode(old).write(to: url)
  let upgraded = SettingsStore(url: url)
  #expect(upgraded.loadError == nil)
  #expect(upgraded.preferences.shortcut("TYPE_COPY") == Shortcut(8, [.option]))
  #expect(upgraded.preferences.shortcut("TYPE_COPY_PIXEL_COLOR") == nil)
  upgraded.set("screenColorFormat", ScreenColor.Format.hsl.rawValue)
  #expect(SettingsStore(url: url).preferences.integer("screenColorFormat") == ScreenColor.Format.hsl.rawValue)
}
