// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter

@Test @MainActor func regionHistoryPersistsPerDisplayAndHonorsLimits() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("history/regions.json")
  let history = RegionHistory(url: url)
  let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
  let first = CGRect(x: 10, y: 20, width: 100, height: 80)
  let second = CGRect(x: 40, y: 50, width: 130, height: 90)
  let other = CGRect(x: 70, y: 80, width: 200, height: 100)
  try history.record(display: "one", rectangle: first, limit: 3)
  try history.record(display: "two", rectangle: other, limit: 3)
  try history.record(display: "one", rectangle: second, limit: 3)
  try history.record(display: "one", rectangle: first, limit: 3)
  let restored = RegionHistory(url: url)
  #expect(restored.regions(display: "one", bounds: bounds, limit: 3) == [second, first])
  #expect(restored.regions(display: "two", bounds: bounds, limit: 3) == [other])
  #expect(restored.regions(display: "one", bounds: bounds, limit: 0).isEmpty)
  #expect(
    restored.regions(display: "one", bounds: CGRect(x: 0, y: 0, width: 100, height: 100), limit: 3)
      .isEmpty)
  try restored.record(display: "one", rectangle: second, limit: 1)
  #expect(RegionHistory(url: url).regions(display: "one", bounds: bounds, limit: 10) == [second])
  try restored.clear()
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func corruptRegionHistoryIsPreservedUntilExplicitlyCleared() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("regions.json")
  let original = Data("invalid history".utf8)
  try original.write(to: url)
  let history = RegionHistory(url: url)
  #expect(history.loadError != nil)
  #expect(throws: (any Error).self) {
    try history.record(
      display: "one", rectangle: CGRect(x: 0, y: 0, width: 10, height: 10), limit: 10)
  }
  #expect(try Data(contentsOf: url) == original)
  try history.clear()
  try history.record(
    display: "one", rectangle: CGRect(x: 0, y: 0, width: 10, height: 10), limit: 10)
  #expect(history.loadError == nil)
}
