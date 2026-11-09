// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

private func historyFixture() -> CGImage {
  let context = CGContext(
    data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 80 * 4,
    space: CGColorSpace(name: CGColorSpace.displayP3)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for y in 0..<60 {
    for x in 0..<80 {
      context.setFillColor(CGColor(red: CGFloat(x) / 80, green: CGFloat(y) / 60, blue: 0.4, alpha: 1))
      context.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }
  }
  return context.makeImage()!
}

private func historyPixels(_ image: CGImage) -> [UInt8] {
  let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                   count: image.width * image.height * 4))
}

private func flush(_ history: CaptureHistory) async throws {
  let result: Result<Void, Error> = await withCheckedContinuation { continuation in
    history.flush { continuation.resume(returning: $0) }
  }
  try result.get()
}

private func entries(_ history: CaptureHistory, display: String = "main", limit: Int = 100) async throws
  -> [CaptureHistoryEntry] {
  let result: Result<[CaptureHistoryEntry], Error> = await withCheckedContinuation { continuation in
    history.list(display: display, bounds: CGRect(x: 0, y: 0, width: 40, height: 30), scale: 2, limit: limit) {
      continuation.resume(returning: $0)
    }
  }
  return try result.get()
}

private func snapshot(_ history: CaptureHistory, id: UUID) async throws -> CaptureHistorySnapshot {
  let result: Result<CaptureHistorySnapshot, Error> = await withCheckedContinuation { continuation in
    history.snapshot(id: id) { continuation.resume(returning: $0) }
  }
  return try result.get()
}

@Test @MainActor func screenshotHistoryStoresOnlySelectedPixelsAndEditableAnnotations() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let archive = CaptureHistory(directory: directory) { error in Issue.record("History failed: \(error)") }
  var document = CaptureDocument(image: historyFixture(), logicalSize: CGSize(width: 40, height: 30))
  document.selection = CGRect(x: 5.5, y: 7, width: 18, height: 12)
  let line = Annotation(tool: .arrow, points: [CGPoint(x: 7, y: 9), CGPoint(x: 20, y: 17)])
  var redact = Annotation(tool: .pixelate, points: [CGPoint(x: 5.5, y: 7), CGPoint(x: 13, y: 14)], width: 4)
  redact.traditionalPixelation = false
  document.replaceAnnotations([line, redact])
  let original = try ImageRenderer.render(document)
  let saved = try CaptureHistorySnapshot.make(document: document, display: "main")
  #expect(saved.image.width == 36 && saved.image.height == 24)
  #expect(saved.entry.annotations[0].points == [CGPoint(x: 1.5, y: 2), CGPoint(x: 14.5, y: 10)])
  #expect(historyPixels(saved.image) == historyPixels(try #require(document.image.cropping(to: document.pixelSelection))))
  archive.record(saved, limit: 100)
  try await flush(archive)
  let reopened = CaptureHistory(directory: directory) { _ in }
  let listed = try await entries(reopened)
  #expect(listed.count == 1 && listed[0].id == saved.entry.id)
  let restored = try await snapshot(reopened, id: saved.entry.id)
  #expect(restored.image.width == 36 && restored.image.height == 24)
  #expect(restored.image.colorSpace?.copyICCData() == saved.image.colorSpace?.copyICCData())
  #expect(historyPixels(try ImageRenderer.render(restored.document(undoLimit: 100))) == historyPixels(original))
  var edited = restored.document(undoLimit: 100)
  var annotations = edited.annotations
  annotations[0].color = RGBA(0, 0, 1)
  edited.replaceAnnotations(annotations)
  #expect(historyPixels(try ImageRenderer.render(edited)) != historyPixels(original))
  let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  let file = directory.appendingPathComponent(restored.entry.payloadFile)
  let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
  #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test @MainActor func screenshotHistoryPrunesAndLoadsImagesOnDemand() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let archive = CaptureHistory(directory: directory) { _ in }
  var document = CaptureDocument(image: historyFixture(), logicalSize: CGSize(width: 40, height: 30))
  document.selection = CGRect(x: 4, y: 4, width: 10, height: 10)
  let first = try CaptureHistorySnapshot.make(document: document, display: "main")
  document.selection = CGRect(x: 6, y: 6, width: 10, height: 10)
  let second = try CaptureHistorySnapshot.make(document: document, display: "main")
  document.selection = CGRect(x: 8, y: 8, width: 10, height: 10)
  let third = try CaptureHistorySnapshot.make(document: document, display: "other")
  archive.record(first, limit: 2)
  archive.record(second, limit: 2)
  archive.record(third, limit: 2)
  try await flush(archive)
  #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.entry.payloadFile).path))
  let reopened = CaptureHistory(directory: directory) { _ in }
  #expect(try await entries(reopened).map(\.id) == [second.entry.id])
  #expect(try await entries(reopened, display: "other").map(\.id) == [third.entry.id])
  #expect(try await entries(reopened, limit: 0).isEmpty)
  try FileManager.default.removeItem(at: directory.appendingPathComponent(second.entry.payloadFile))
  #expect(try await entries(reopened).count == 1)
  do { _ = try await snapshot(reopened, id: second.entry.id); Issue.record("Missing image was accepted") }
  catch {}
  let cleared: Result<Void, Error> = await withCheckedContinuation { continuation in
    reopened.clear { continuation.resume(returning: $0) }
  }
  try cleared.get()
  #expect(try await entries(reopened).isEmpty)
}

@Test @MainActor func screenshotHistoryDoesNotOverwriteCorruptManifest() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let manifest = directory.appendingPathComponent("history.json")
  let original = Data("corrupt".utf8)
  try original.write(to: manifest)
  let archive = CaptureHistory(directory: directory) { _ in }
  var document = CaptureDocument(image: historyFixture(), logicalSize: CGSize(width: 40, height: 30))
  document.selection = CGRect(x: 2, y: 2, width: 10, height: 10)
  archive.record(try CaptureHistorySnapshot.make(document: document, display: "main"), limit: 2)
  do { try await flush(archive); Issue.record("Corrupt history was accepted") } catch {}
  #expect(try Data(contentsOf: manifest) == original)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["history.json"])
}

@Test @MainActor func redactionAtSelectionEdgeMatchesPreview() throws {
  var document = CaptureDocument(image: historyFixture(), logicalSize: CGSize(width: 40, height: 30))
  document.selection = CGRect(x: 5.5, y: 7, width: 18, height: 12)
  document.add(Annotation(
    tool: .pixelate, points: [CGPoint(x: 5.5, y: 7), CGPoint(x: 13, y: 14)], width: 4))
  let preview = try ImageRenderer.render(document, includeSelection: false)
  let selected = try #require(preview.cropping(to: document.pixelSelection))
  #expect(historyPixels(selected) == historyPixels(try ImageRenderer.render(document)))
}

@Test @MainActor func filtersAtSelectionEdgeMatchPreview() throws {
  for tool in [Tool.pixelate, .invert] {
    var document = CaptureDocument(image: historyFixture(), logicalSize: CGSize(width: 40, height: 30))
    document.selection = CGRect(x: 6, y: 7, width: 18, height: 12)
    var annotation = Annotation(tool: tool, points: [CGPoint(x: 4, y: 5), CGPoint(x: 13, y: 14)], width: 4)
    annotation.traditionalPixelation = true
    document.add(annotation)
    let preview = try ImageRenderer.render(document, includeSelection: false)
    let selected = try #require(preview.cropping(to: document.pixelSelection))
    #expect(historyPixels(selected) == historyPixels(try ImageRenderer.render(document)), "\(tool)")
  }
}

@Test func screenshotHistoryCompositePlacesImageAtItsOriginalPosition() throws {
  var document = CaptureDocument(image: historyFixture(), logicalSize: CGSize(width: 40, height: 30))
  document.selection = CGRect(x: 5.5, y: 7, width: 18, height: 12)
  let saved = try CaptureHistorySnapshot.make(document: document, display: "main")
  let composite = try saved.composite(over: historyFixture())
  let shown = try #require(composite.cropping(to: document.pixelSelection))
  #expect(historyPixels(shown) == historyPixels(saved.image))
}

@Test func screenshotHistoryUpgradeKeepsCustomShortcuts() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 8
  old.shortcuts["TYPE_PENCIL"] = Shortcut(43)
  try JSONEncoder().encode(old).write(to: url)
  let upgraded = SettingsStore(url: url).preferences
  #expect(upgraded.shortcut("TYPE_PENCIL") == Shortcut(43))
  #expect(upgraded.shortcut("TYPE_PREVIOUS_CAPTURE") == nil)
  #expect(upgraded.shortcut("TYPE_NEXT_CAPTURE") == Shortcut(47))
}

@Test @MainActor func switchingScreenshotDocumentsPreservesIndependentUndo() throws {
  _ = NSApplication.shared
  let screen = try #require(NSScreen.main)
  let canvas = CanvasView(frame: CapturedScreen(image: historyFixture(), screen: screen))
  let liveAnnotation = Annotation(tool: .line, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)])
  canvas.edits.groupsByEvent = false
  canvas.edits.beginUndoGrouping()
  canvas.add(liveAnnotation)
  canvas.edits.endUndoGrouping()
  let live = canvas.document
  let liveEdits = canvas.edits
  canvas.replaceDocument(CaptureDocument(image: historyFixture(), logicalSize: screen.frame.size))
  let historyAnnotation = Annotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 30)])
  canvas.edits.groupsByEvent = false
  canvas.edits.beginUndoGrouping()
  canvas.add(historyAnnotation)
  canvas.edits.endUndoGrouping()
  let history = canvas.document
  let historyEdits = canvas.edits
  canvas.replaceDocument(live, edits: liveEdits)
  #expect(canvas.edits.canUndo)
  canvas.edits.undo()
  #expect(canvas.document.annotations.isEmpty)
  canvas.replaceDocument(history, edits: historyEdits)
  #expect(canvas.edits.canUndo)
  canvas.edits.undo()
  #expect(canvas.document.annotations.isEmpty)
}
