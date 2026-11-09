// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@MainActor private func refreshFrame(_ color: NSColor) -> CapturedScreen {
  _ = NSApplication.shared
  let context = CGContext(
    data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(color.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
  return CapturedScreen(image: context.makeImage()!, screen: NSScreen.main!)
}

@Test @MainActor func refreshingPreservesSelectionAnnotationsAndUndo() {
  let canvas = CanvasView(frame: refreshFrame(.red))
  canvas.setSelection(CGRect(x: 100, y: 100, width: 200, height: 150))
  let annotation = Annotation(tool: .arrow, points: [CGPoint(x: 120, y: 120), CGPoint(x: 200, y: 180)])
  canvas.edits.groupsByEvent = false
  canvas.edits.beginUndoGrouping()
  canvas.add(annotation)
  canvas.edits.endUndoGrouping()
  let prior = canvas.document.image.dataProvider?.data
  let undo = canvas.edits
  canvas.replaceScreen(refreshFrame(.blue))
  #expect(canvas.document.selection == CGRect(x: 100, y: 100, width: 200, height: 150))
  #expect(canvas.document.annotations == [annotation])
  #expect(canvas.document.image.dataProvider?.data != prior)
  #expect(canvas.edits === undo && canvas.edits.canUndo)
  canvas.edits.undo()
  #expect(canvas.document.annotations.isEmpty)
}

@Test @MainActor func refreshShortcutBeginsOnceAndEndsOnKeyRelease() throws {
  let store = Environment.shared.settings
  let previous = store.preferences
  defer { store.update { $0 = previous } }
  store.update {
    $0.shortcuts[Tool.refreshCapture.legacyName] = Shortcut(96)
    $0.unassignedShortcuts.remove(Tool.refreshCapture.legacyName)
  }
  let canvas = CanvasView(frame: refreshFrame(.red))
  var started = 0
  var ended = 0
  canvas.onRefreshStart = { started += 1; return true }
  canvas.onRefreshEnd = { ended += 1 }
  func key(_ type: NSEvent.EventType, repeatKey: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: repeatKey, keyCode: 96)!
  }
  #expect(canvas.handleKey(key(.keyDown)))
  #expect(canvas.handleKey(key(.keyDown, repeatKey: true)))
  canvas.keyUp(with: key(.keyUp))
  #expect(started == 1 && ended == 1)
  #expect(!canvas.finishRefreshHold())
}

@Test @MainActor func holdingRefreshRevealsScreenAndRestoresEditorOnRelease() async throws {
  let old = refreshFrame(.red)
  let updated = refreshFrame(.blue)
  let controller = AppController(command: nil)
  let session = CaptureSession(frames: [old], command: NativeCommand(), app: controller,
                               refreshSource: { [updated] })
  let surface = session.active
  defer {
    surface.toolbar.close()
    surface.window.close()
  }
  let canvas = surface.canvas
  canvas.setSelection(CGRect(x: 100, y: 100, width: 200, height: 150))
  let annotation = Annotation(tool: .arrow, points: [CGPoint(x: 120, y: 120), CGPoint(x: 200, y: 180)])
  canvas.add(annotation)
  let previousOpacity = surface.window.isOpaque
  let previousAlpha = canvas.alphaValue
  let previousMouse = surface.window.ignoresMouseEvents
  let keyDown = try #require(NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 96))
  let keyUp = try #require(NSEvent.keyEvent(
    with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 96))
  #expect(canvas.handleKey(keyDown))
  #expect(canvas.alphaValue == 0 && !surface.window.isOpaque && surface.window.ignoresMouseEvents)
  canvas.keyUp(with: keyUp)
  for _ in 0..<100 where canvas.alphaValue == 0 { try await Task.sleep(for: .milliseconds(10)) }
  #expect(canvas.alphaValue == previousAlpha && surface.window.isOpaque == previousOpacity)
  #expect(surface.window.ignoresMouseEvents == previousMouse)
  #expect(canvas.document.selection == CGRect(x: 100, y: 100, width: 200, height: 150))
  #expect(canvas.document.annotations == [annotation])
  #expect(canvas.document.image.dataProvider?.data == updated.image.dataProvider?.data)
}

@Test func refreshUpgradeDoesNotReplaceExistingShortcut() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 9
  old.tools = [.copy]
  old.shortcuts["TYPE_PENCIL"] = Shortcut(96)
  try JSONEncoder().encode(old).write(to: url)
  let updated = SettingsStore(url: url).preferences
  #expect(updated.tools == [.copy, .refreshCapture])
  #expect(updated.shortcut("TYPE_PENCIL") == Shortcut(96))
  #expect(updated.shortcut(Tool.refreshCapture.legacyName) == nil)
}
