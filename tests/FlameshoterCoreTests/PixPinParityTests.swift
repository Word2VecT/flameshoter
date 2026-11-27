// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import CoreImage
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@MainActor private func parityImage(width: Int = 300, height: Int = 200) -> CGImage {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(NSColor.white.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(NSColor.blue.cgColor)
  context.fill(CGRect(x: 135, y: 85, width: 30, height: 30))
  return context.makeImage()!
}

@Test @MainActor func spotlightKeepsAperturePixelsAndDimsTheOutside() throws {
  let image = parityImage()
  var document = CaptureDocument(image: image, logicalSize: CGSize(width: 300, height: 200))
  var spotlight = Annotation(
    tool: .spotlight, points: [.init(x: 100, y: 50), .init(x: 200, y: 150)], width: 2)
  spotlight.effectOpacity = 0.6
  document.add(spotlight)
  let output = try ImageRenderer.render(document)
  let outside = try #require(ScreenColor.sample(output, point: .init(x: 30, y: 30), scale: 1))
  let aperture = try #require(ScreenColor.sample(output, point: .init(x: 115, y: 70), scale: 1))
  #expect((95...110).contains(outside.red))
  #expect(aperture.red == 255 && aperture.green == 255 && aperture.blue == 255)
  document.selection = CGRect(x: 20, y: 20, width: 260, height: 160)
  let full = try ImageRenderer.render(document, includeSelection: false)
  let cropped = try ImageRenderer.render(document)
  #expect(
    try ImageEncoder.data(cropped) == ImageEncoder.data(full.cropping(to: document.pixelSelection)!)
  )
}

@Test @MainActor func magnificationSamplesTheCenterAndMatchesCroppedPreview() throws {
  var document = CaptureDocument(image: parityImage(), logicalSize: CGSize(width: 300, height: 200))
  var lens = Annotation(
    tool: .magnify, points: [.init(x: 100, y: 50), .init(x: 200, y: 150)], width: 2)
  lens.magnification = 2
  document.add(lens)
  let image = try ImageRenderer.render(document)
  let enlarged = try #require(ScreenColor.sample(image, point: .init(x: 172, y: 100), scale: 1))
  #expect(enlarged.blue > 240 && enlarged.red < 20)
  document.selection = CGRect(x: 40, y: 30, width: 220, height: 140)
  #expect(
    try ImageEncoder.data(ImageRenderer.render(document))
      == ImageEncoder.data(
        ImageRenderer.render(document, includeSelection: false).cropping(
          to: document.pixelSelection)!))
}

@Test @MainActor func watermarkStaysInsideItsRectangleAndIsArchived() throws {
  var document = CaptureDocument(image: parityImage(), logicalSize: CGSize(width: 300, height: 200))
  var watermark = Annotation(
    tool: .watermark, points: [.init(x: 40, y: 30), .init(x: 260, y: 170)], color: RGBA(0, 0, 0))
  watermark.text = "测试 Internal"
  watermark.fontSize = 18
  watermark.effectOpacity = 0.4
  document.add(watermark)
  let image = try ImageRenderer.render(document)
  #expect(try ImageEncoder.data(image) != ImageEncoder.data(document.image))
  let outside = try #require(ScreenColor.sample(image, point: .init(x: 10, y: 10), scale: 1))
  #expect(outside.red == 255)
  #expect(
    try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(watermark)) == watermark)
  var old = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(watermark)) as? [String: Any])
  old.removeValue(forKey: "magnification")
  old.removeValue(forKey: "effectOpacity")
  let legacy = try JSONDecoder().decode(
    Annotation.self, from: JSONSerialization.data(withJSONObject: old))
  #expect(legacy.effectOpacity == nil && legacy.text == watermark.text)
}

@Test @MainActor func polylineClickGesturesFinishCancelAndUndoAsOneAnnotation() throws {
  let screen = try #require(NSScreen.main)
  let canvas = CanvasView(
    frame: CapturedScreen(
      image: parityImage(), screen: screen,
      imageLogicalSize: CGSize(width: 300, height: 200)))
  let window = CaptureWindow(
    contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  canvas.setSelection(canvas.bounds)
  canvas.edits.groupsByEvent = false
  canvas.setTool(.polyline)
  func click(_ p: CGPoint, count: Int = 1) {
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: canvas.convert(p, to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: count, pressure: 1)!
    canvas.mouseDown(with: event)
    canvas.mouseUp(with: event)
  }
  click(.init(x: 50, y: 50))
  click(.init(x: 140, y: 60))
  canvas.edits.beginUndoGrouping()
  click(.init(x: 220, y: 130), count: 2)
  canvas.edits.endUndoGrouping()
  let annotation = try #require(canvas.document.annotations.first)
  #expect(annotation.points.count == 3)
  #expect(annotation.hitTest(.init(x: 90, y: 54)))
  #expect(!annotation.hitTest(.init(x: 90, y: 120)))
  canvas.edits.undo()
  #expect(canvas.document.annotations.isEmpty)
  canvas.edits.redo()
  #expect(canvas.document.annotations == [annotation])
  click(.init(x: 40, y: 40))
  let escape = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
  #expect(canvas.handleKey(escape))
  #expect(canvas.preview == nil && canvas.document.annotations == [annotation])
}

@Test func redactionMatchesOnlyEnabledSensitivePatterns() {
  let text =
    "邮箱 alice@example.com 电话 +86 13800138000 IP 192.168.1.24 URL https://example.com/path token=abc123"
  let matches = AutoRedaction.ranges(in: text, options: RedactionOptions())
  let values = matches.map { (text as NSString).substring(with: $0) }
  #expect(values.contains("alice@example.com"))
  #expect(values.contains(where: { $0.contains("13800138000") }))
  #expect(values.contains("192.168.1.24"))
  #expect(values.contains("https://example.com/path"))
  #expect(values.contains("token=abc123"))
  #expect(AutoRedaction.ranges(in: "version 3.6 build 1234", options: RedactionOptions()).isEmpty)
  #expect(
    AutoRedaction.ranges(
      in: text,
      options: RedactionOptions(
        emails: false, phones: false,
        addresses: false, faces: false, credentials: false)
    ).isEmpty)
}

@Test func redactionConvertsVisionCoordinatesAndClipsToSelection() {
  let selection = CGRect(x: 100, y: 50, width: 400, height: 200)
  let masks = AutoRedaction.annotations(
    regions: [
      CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
      CGRect(x: 0, y: 0, width: 1, height: 1),
    ], selection: selection, scale: 2)
  #expect(masks.count == 2)
  #expect(masks[0].bounds == CGRect(x: 198.5, y: 98.5, width: 103, height: 53))
  #expect(masks[1].bounds == selection)
  #expect(masks.allSatisfy { !$0.traditionalPixelation && $0.tool == .pixelate })
}

@Test(.requiresOnDeviceVision) @MainActor func localRedactionFindsAnEmailWithoutCoveringTheWholeLine() async throws {
  let image = NSImage(size: CGSize(width: 1200, height: 200))
  image.lockFocus()
  NSColor.white.setFill()
  CGRect(x: 0, y: 0, width: 1200, height: 200).fill()
  ("Contact alice@example.com today" as NSString).draw(
    at: .init(x: 30, y: 75),
    withAttributes: [
      .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black,
    ])
  image.unlockFocus()
  let source = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
  let regions = try await AutoRedaction.regions(
    source,
    options: RedactionOptions(phones: false, addresses: false, faces: false, credentials: false))
  #expect(regions.count == 1)
  #expect(try #require(regions.first).width < 0.65)
  #expect(try #require(regions.first).minX > 0.1)
}

@Test @MainActor func documentExportsRoundTripUnicodeAndParagraphs() throws {
  let text = "Flameshoter 文档\n\n第一段 <>&\nSecond paragraph."
  for format in [DocumentExport.Format.docx, .rtf] {
    let data = try DocumentExport.data(text, format: format)
    let result = try NSAttributedString(
      data: data,
      options: [
        .documentType: format == .docx ? NSAttributedString.DocumentType.officeOpenXML : .rtf
      ], documentAttributes: nil)
    #expect(result.string.trimmingCharacters(in: .newlines) == text)
  }
  #expect(try DocumentExport.data(text, format: .md) == Data(text.utf8))
}

@Test(.requiresOnDeviceVision) @MainActor func localDocumentRecognitionReturnsEditableText() async throws {
  let image = NSImage(size: CGSize(width: 600, height: 200))
  image.lockFocus()
  NSColor.white.setFill()
  CGRect(x: 0, y: 0, width: 600, height: 200).fill()
  ("Document 123" as NSString).draw(
    at: .init(x: 30, y: 80),
    withAttributes: [
      .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black,
    ])
  image.unlockFocus()
  let source = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
  #expect(try await DocumentRecognition.text(source).contains("Document 123"))
}

@Test @MainActor func recognizesCode128AlongsideQRCode() async throws {
  let filter = try #require(CIFilter(name: "CICode128BarcodeGenerator"))
  filter.setValue(Data("FLAMESHOTER-123".utf8), forKey: "inputMessage")
  let output = try #require(filter.outputImage).transformed(by: .init(scaleX: 4, y: 3))
  let image = try #require(CIContext().createCGImage(output, from: output.extent))
  let codes = try await ImageRecognition.barcodes(image)
  #expect(codes.contains { $0.payload == "FLAMESHOTER-123" && $0.symbology.contains("Code128") })
}

@Test @MainActor func pinRotationsAreLosslessAndRestorable() throws {
  let original = parityImage(width: 300, height: 200)
  var rotated = original
  for _ in 0..<4 {
    rotated = try PinImageTransform.apply(rotated, quarterTurns: 1, mirrored: false)
  }
  #expect(try ImageEncoder.data(rotated) == ImageEncoder.data(original))
  let mirrored = try PinImageTransform.apply(original, quarterTurns: 0, mirrored: true)
  #expect(
    try ImageEncoder.data(PinImageTransform.apply(mirrored, quarterTurns: 0, mirrored: true))
      == ImageEncoder.data(original))
  let pin = PinWindowController(image: original)
  defer { pin.close() }
  pin.rotateClockwise(nil)
  #expect(pin.displayedImage.width == 200 && pin.displayedImage.height == 300)
  pin.toggleLock(nil)
  pin.rotateClockwise(nil)
  #expect(pin.quarterTurns == 1 && pin.locked)
  let record = ArchivedPin(
    id: UUID(), kind: .image, created: Date(), frame: .zero, opacity: 1,
    payloadFile: "test.png", quarterTurns: 1, mirrored: true, locked: true)
  let restored = PinWindowController(image: original)
  defer { restored.close() }
  restored.restoreTransform(from: record)
  #expect(restored.quarterTurns == 1 && restored.mirrored && restored.locked)
  var payload = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
  for key in ["quarterTurns", "mirrored", "locked"] { payload.removeValue(forKey: key) }
  let legacy = try JSONDecoder().decode(
    ArchivedPin.self, from: JSONSerialization.data(withJSONObject: payload))
  #expect(legacy.quarterTurns == nil && legacy.locked == nil)
}

@Test @MainActor func recordingShortcutsSkipTypingAndKeepNavigation() throws {
  func event(code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code)!
  }
  #expect(RecordingOverlays.shortcutLabel(for: event(code: 0)) == nil)
  #expect(RecordingOverlays.shortcutLabel(for: event(code: 0, flags: .shift)) == nil)
  #expect(RecordingOverlays.shortcutLabel(for: event(code: 8, flags: .command)) == "⌘C")
  #expect(RecordingOverlays.shortcutLabel(for: event(code: 123)) == "←")
  var options = RecordingOptions()
  options.showMouseClicks = true
  let config = options.configuration(
    selection: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
  #expect(config.showMouseClicks && config.pixelFormat == kCVPixelFormatType_32BGRA)
}

@Test @MainActor func pinEditorOffersAcceptAndPreservesOriginalPixelsOnCancel() throws {
  let source = parityImage()
  let pin = PinWindowController(image: source)
  let editor = PinAnnotationController(pin: pin, app: AppController(command: nil))
  defer {
    editor.close()
    pin.close()
  }
  let window = try #require(editor.window as? CaptureWindow)
  #expect(window.captureToolbar?.button(for: .accept) != nil)
  #expect(window.captureToolbar?.button(for: .screenRecording) == nil)
  #expect(try ImageEncoder.data(editor.canvas.rendered()) == ImageEncoder.data(source))
}

@Test @MainActor func smallAndShallowPinEditorsKeepControlsOutsideSourceCoordinates() throws {
  for dimensions in [(100, 20), (1500, 30)] {
    let source = parityImage(width: dimensions.0, height: dimensions.1)
    let pin = PinWindowController(image: source)
    let editor = PinAnnotationController(pin: pin, app: AppController(command: nil))
    defer {
      editor.close()
      pin.close()
    }
    let window = try #require(editor.window as? CaptureWindow)
    let viewport = try #require(window.contentView)
    let toolbar = try #require(window.captureToolbar)
    window.orderFront(nil)
    #expect(viewport.bounds.width >= 700 && viewport.bounds.height >= 400)
    #expect(editor.canvas.frame.minX > 0 && editor.canvas.frame.minY > 0)
    #expect(try ImageEncoder.data(editor.canvas.rendered()) == ImageEncoder.data(source))
    #expect(
      editor.canvas.document.pixelSelection.size
        == CGSize(width: source.width, height: source.height))
    for control in toolbar.root.controls {
      #expect(
        viewport.bounds.insetBy(dx: -8, dy: -8).contains(
          control.convert(control.bounds, to: viewport)))
    }
    editor.canvas.setTool(.watermark)
    toolbar.toggleInspector()
    let inspector = try #require(toolbar.inspectorWindow)
    #expect(inspector.contentView!.bounds.height >= 400)
    #expect(inspector.level.rawValue > window.level.rawValue)
    toolbar.dismissInspector()
  }
}

@Test func parityUpgradeAddsToolsWithoutStealingCustomShortcuts() throws {
  var preferences = Preferences()
  preferences.schemaVersion = 12
  preferences.tools = [.copy]
  preferences.shortcuts["TYPE_COPY"] = Shortcut(14)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  try JSONEncoder().encode(preferences).write(to: url)
  let updated = SettingsStore(url: url)
  #expect(updated.preferences.schemaVersion == 13)
  #expect(updated.preferences.unassignedShortcuts.contains(Tool.magnify.legacyName))
  #expect(updated.preferences.shortcuts["TYPE_COPY"] == Shortcut(14))
  updated.update { $0.tools.removeAll { $0 == .watermark } }
  #expect(!SettingsStore(url: url).preferences.tools.contains(.watermark))
}

@Test @MainActor func exportPreviewDiscardsAnOlderEncodingResult() async throws {
  let preview = ImageExportPreview(
    image: parityImage(), format: "png", quality: 75, optimize: false
  ) {
    _, format, _, _ in
    await Task.detached {
      try? await Task.sleep(for: .milliseconds(format == "png" ? 450 : 10))
      return Data(format.utf8)
    }.value
  }
  defer { preview.cancel() }
  try await Task.sleep(for: .milliseconds(240))
  preview.request(format: "jpeg")
  try await Task.sleep(for: .milliseconds(650))
  #expect(preview.encodedData == Data("jpeg".utf8))
  #expect(preview.format == "jpeg")
}

@Test @MainActor func exportPreviewUsesTheSameBytesAsImageExport() async throws {
  let image = parityImage()
  let preview = ImageExportPreview(image: image, format: "png", quality: 75, optimize: false)
  defer { preview.cancel() }
  for _ in 0..<30 where preview.encodedData == nil { try await Task.sleep(for: .milliseconds(50)) }
  #expect(try #require(preview.encodedData) == ImageEncoder.data(image, format: "png"))
}

@Test @MainActor func effectInspectorHasVisibleSizeAboveTheCaptureWindow() throws {
  let screen = try #require(NSScreen.main)
  let canvas = CanvasView(
    frame: CapturedScreen(
      image: parityImage(), screen: screen,
      imageLogicalSize: CGSize(width: 800, height: 700)))
  let window = CaptureWindow(
    contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.level = .statusBar
  window.contentView = canvas
  window.orderFront(nil)
  defer { window.close() }
  canvas.setSelection(CGRect(x: 80, y: 80, width: 600, height: 500))
  canvas.setTool(.watermark)
  let toolbar = CaptureToolbar(canvas: canvas)
  defer { toolbar.close() }
  toolbar.toggleInspector()
  let inspector = try #require(toolbar.inspectorWindow)
  inspector.layoutIfNeeded()
  #expect(inspector.level.rawValue > window.level.rawValue)
  #expect(inspector.contentView!.bounds.width >= 340)
  #expect(inspector.contentView!.bounds.height >= 400)
}
