// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Flameshoter
@testable import FlameshoterCore

private func loadPins(_ archive: PinArchive) async throws -> [ArchivedPin] {
  let result: Result<[ArchivedPin], Error> = await withCheckedContinuation { continuation in
    archive.load { continuation.resume(returning: $0) }
  }
  return try result.get()
}
private func loadPin(_ archive: PinArchive, id: UUID) async throws -> LoadedPin {
  let result: Result<LoadedPin, Error> = await withCheckedContinuation { continuation in
    archive.payload(for: id) { continuation.resume(returning: $0) }
  }
  return try result.get()
}
private func flushPins(_ archive: PinArchive) async throws {
  let result: Result<Void, Error> = await withCheckedContinuation { continuation in
    archive.flush { continuation.resume(returning: $0) }
  }
  try result.get()
}

@Test func pinHistoryPersistsUpdatesAndRemovesOnlyTrimmedEntries() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let archive = PinArchive(directory: directory) { error in Issue.record("Archive failed: \(error)")
  }
  let created = Date(timeIntervalSince1970: 100)
  var first = ArchivedPin(
    id: UUID(), kind: .text, created: created, closed: nil,
    frame: CGRect(x: 20, y: 30, width: 320, height: 240), opacity: 0.8, payloadFile: "")
  let second = ArchivedPin(
    id: UUID(), kind: .gif, created: created, closed: created,
    frame: CGRect(x: 40, y: 50, width: 200, height: 160), opacity: 1, payloadFile: "")
  archive.add(first) { Data("old".utf8) }
  archive.add(second) { Data("animation".utf8) }
  first.closed = Date(timeIntervalSince1970: 200)
  first.frame.origin.x = 75
  let changed = first
  let save: Result<ArchivedPin, Error> = await withCheckedContinuation { continuation in
    archive.update(changed, payload: Data("edited".utf8)) { continuation.resume(returning: $0) }
  }
  #expect(try save.get().closed == changed.closed)
  try await flushPins(archive)
  let reopened = PinArchive(directory: directory) { error in
    Issue.record("Archive failed: \(error)")
  }
  let loaded = try await loadPins(reopened)
  #expect(loaded.count == 2)
  let restored = try await loadPin(reopened, id: first.id)
  #expect(restored.data == Data("edited".utf8))
  #expect(restored.record.closed == first.closed && restored.record.frame == first.frame)
  #expect(restored.record.opacity == 0.8)
  let directoryMode = try #require(
    try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
  )
  #expect(directoryMode.intValue & 0o777 == 0o700)
  let fileMode = try #require(
    try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent(restored.record.payloadFile).path)[.posixPermissions]
      as? NSNumber)
  #expect(fileMode.intValue & 0o777 == 0o600)
  reopened.remove([first.id])
  try await flushPins(reopened)
  let remaining = try await loadPins(PinArchive(directory: directory) { _ in })
  #expect(remaining.count == 1 && remaining[0].id == second.id)
  #expect(try await loadPin(reopened, id: second.id).data == Data("animation".utf8))
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(restored.record.payloadFile).path))
}

@Test func unreadablePinHistoryIsNeverOverwritten() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let manifest = directory.appendingPathComponent("history.json")
  let original = Data("not valid JSON".utf8)
  try original.write(to: manifest)
  let archive = PinArchive(directory: directory) { _ in }
  do {
    _ = try await loadPins(archive)
    Issue.record("Corrupt history was accepted")
  } catch {}
  let record = ArchivedPin(
    id: UUID(), kind: .text, created: Date(), closed: nil, frame: .zero, opacity: 1, payloadFile: ""
  )
  archive.add(record) { Data("new".utf8) }
  do {
    try await flushPins(archive)
    Issue.record("Unreadable history was reported as saved")
  } catch {}
  #expect(try Data(contentsOf: manifest) == original)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["history.json"])
}

@Test func closedPinContentsLoadOnlyWhenRequested() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let archive = PinArchive(directory: directory) { _ in }
  let first = ArchivedPin(
    id: UUID(), kind: .text, created: Date(), closed: Date(), frame: .zero, opacity: 1,
    payloadFile: "")
  let second = ArchivedPin(
    id: UUID(), kind: .text, created: Date(), closed: Date(), frame: .zero, opacity: 1,
    payloadFile: "")
  archive.add(first) { Data("first".utf8) }
  archive.add(second) { Data("second".utf8) }
  try await flushPins(archive)
  let records = try await loadPins(archive)
  let missing = try #require(records.first(where: { $0.id == first.id }))
  try FileManager.default.removeItem(at: directory.appendingPathComponent(missing.payloadFile))
  let reopened = PinArchive(directory: directory) { _ in }
  #expect(try await loadPins(reopened).count == 2)
  #expect(try await loadPin(reopened, id: second.id).data == Data("second".utf8))
  do {
    _ = try await loadPin(reopened, id: first.id)
    Issue.record("A missing payload was accepted")
  } catch {}
  #expect(try await loadPins(reopened).count == 2)
}

@Test func pinHistoryReportsWriteFailureWithoutDamagingExistingFile() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let blocked = root.appendingPathComponent("existing-file")
  let original = Data("existing data".utf8)
  try original.write(to: blocked)
  let archive = PinArchive(directory: blocked.appendingPathComponent("Pins")) { _ in }
  let record = ArchivedPin(
    id: UUID(), kind: .text, created: Date(), closed: nil, frame: .zero, opacity: 1, payloadFile: ""
  )
  archive.add(record) { Data("new pin".utf8) }
  do {
    try await flushPins(archive)
    Issue.record("A failed write was reported as saved")
  } catch {}
  #expect(try Data(contentsOf: blocked) == original)
}

@Test @MainActor func pinnedRichTextPersistsItsCurrentEdits() throws {
  _ = NSApplication.shared
  let original = NSAttributedString(string: "old")
  let pin = ContentPinController(content: .text(original))
  defer { pin.window?.close() }
  let scroll = try #require(pin.window?.contentView as? NSScrollView)
  let editor = try #require(scroll.documentView as? NSTextView)
  editor.textStorage?.setAttributedString(
    NSAttributedString(string: "更新后的文字", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
  let (kind, data) = try pin.archivedPayload()
  guard case .text(let restored) = try PinPersistence.content(kind, data: data) else {
    Issue.record("Text pin was not restored")
    return
  }
  #expect(restored.string == "更新后的文字")
  let font = try #require(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
  #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
}

@Test @MainActor func restoredPinKeepsVisiblePositionAndOpacity() throws {
  _ = NSApplication.shared
  let screen = try #require(NSScreen.screens.first)
  let window = NSWindow(
    contentRect: CGRect(x: 20, y: 20, width: 300, height: 200), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let visible = screen.visibleFrame
  let frame = CGRect(x: visible.minX + 50, y: visible.minY + 50, width: 300, height: 200)
  var record = ArchivedPin(
    id: UUID(), kind: .text, created: Date(), closed: nil, frame: frame, opacity: 0.65,
    payloadFile: "fixture")
  PinPersistence.restoreWindow(window, from: record)
  #expect(window.frame == frame)
  #expect(abs(window.alphaValue - 0.65) < 0.001)
  record.frame = CGRect(x: 1_000_000, y: 1_000_000, width: 300, height: 200)
  PinPersistence.restoreWindow(window, from: record)
  #expect(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) })
}

@Test @MainActor func pinPayloadsRestoreImagesAnimationsColorsAndFiles() throws {
  let context = try #require(
    CGContext(
      data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(NSColor.red.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
  let image = try #require(context.makeImage())
  let restoredImage = try PinPersistence.image(ImageEncoder.data(image))
  #expect(restoredImage.width == 8 && restoredImage.height == 6)
  #expect(
    try #require(ScreenColor.sample(restoredImage, point: CGPoint(x: 4, y: 3), scale: 1)).red > 240)
  let gifData = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(gifData, UTType.gif.identifier as CFString, 2, nil))
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  guard
    case .animated(let gif, let gifType) = try PinPersistence.content(.gif, data: gifData as Data)
  else {
    Issue.record("GIF pin was not restored")
    return
  }
  #expect(gif == gifData as Data && gifType == .gif)
  let webPData = try animatedWebPFixture()
  guard case .animated(let webP, let webPType) = try PinPersistence.content(.webP, data: webPData)
  else {
    Issue.record("WebP pin was not restored")
    return
  }
  #expect(webP == webPData && webPType == .webP)
  guard case .color(let color, _) = try PinPersistence.content(.color, data: Data("#0485f7".utf8))
  else {
    Issue.record("Color pin was not restored")
    return
  }
  #expect(color.string(.hashHex) == "#0485f7")
  let url = URL(fileURLWithPath: "/tmp/pin fixture.txt")
  guard
    case .file(let file) = try PinPersistence.content(.file, data: Data(url.absoluteString.utf8))
  else {
    Issue.record("File pin was not restored")
    return
  }
  #expect(file == url)
}
