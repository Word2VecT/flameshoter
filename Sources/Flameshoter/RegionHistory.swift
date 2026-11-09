// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics

struct RegionHistoryEntry: Codable, Equatable {
  let display: String
  let rectangle: CGRect
}

@MainActor final class RegionHistory {
  private let url: URL
  private var entries: [RegionHistoryEntry] = []
  private(set) var loadError: Error?

  init(url: URL) {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        entries = try JSONDecoder().decode([RegionHistoryEntry].self, from: Data(contentsOf: url))
      } catch { loadError = error }
    }
  }

  static func displayIdentifier(_ screen: NSScreen) -> String {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return "unknown" }
    if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
      return CFUUIDCreateString(nil, uuid) as String
    }
    return "display-\(number.uint32Value)"
  }

  func regions(display: String, bounds: CGRect, limit: Int) -> [CGRect] {
    guard limit > 0, loadError == nil else { return [] }
    return entries.filter { $0.display == display && bounds.contains($0.rectangle) }
      .suffix(limit).map(\.rectangle)
  }

  func record(display: String, rectangle: CGRect, limit: Int) throws {
    guard limit > 0, !rectangle.isEmpty, !rectangle.isNull else { return }
    if let loadError { throw loadError }
    let entry = RegionHistoryEntry(display: display, rectangle: rectangle.standardized)
    var updated = entries.filter { $0 != entry }
    updated.append(entry)
    if updated.count > limit { updated.removeFirst(updated.count - limit) }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try JSONEncoder().encode(updated).write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    entries = updated
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    entries.removeAll()
    loadError = nil
  }
}
