// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@MainActor private func nativeFrame() -> CapturedScreen {
  _ = NSApplication.shared
  let image = CGContext(
    data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
  return CapturedScreen(image: image, screen: NSScreen.main!)
}
@Test @MainActor func nativeMaterialsAndToolbarLayout() throws {
  let canvas = CanvasView(frame: nativeFrame())
  let window = CaptureWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  canvas.setSelection(CGRect(x: 100, y: 100, width: 400, height: 250))
  #expect(canvas.selectionGlass.style == .clear)
  #expect(canvas.frost.material == .fullScreenUI)
  #expect(canvas.frost.blendingMode == .withinWindow)
  #expect(canvas.selectionGlass.hitTest(CGPoint(x: 10, y: 10)) == nil)
  #expect(canvas.frost.hitTest(CGPoint(x: 10, y: 10)) == nil)
  #expect(canvas.selectedImage.image != nil)
  #expect(canvas.dimensions.superview === canvas.glassContent)
  let toolbar = CaptureToolbar(canvas: canvas)
  toolbar.refresh()
  #expect(toolbar.root.frame.width > 300)
  #expect(toolbar.root.frame.height >= 32)
  toolbar.close()
  window.close()
}
@Test @MainActor func appKitUndoSupportsAnnotationChanges() {
  let canvas = CanvasView(frame: nativeFrame())
  let original = Annotation(
    tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)])
  canvas.edits.groupsByEvent = false
  canvas.edits.beginUndoGrouping()
  canvas.add(original)
  canvas.edits.endUndoGrouping()
  #expect(canvas.document.annotations.count == 1)
  canvas.edits.undo()
  #expect(canvas.document.annotations.isEmpty)
  canvas.edits.redo()
  #expect(canvas.document.annotations == [original])
}
@Test func nativeCLIRegionParsing() throws {
  let command = try NativeCommand.parse([
    "gui", "--region", "200x100+20+30", "-c", "--delay", "2000",
  ])
  #expect(command.region == CGRect(x: 20, y: 30, width: 200, height: 100))
  #expect(command.copy)
  #expect(command.delay == 2000)
  #expect(throws: CommandError.self) { try NativeCommand.parse(["gui", "--region", "invalid"]) }
}

@Test @MainActor func dockFollowsOrdinaryWindowsAndKeepsMenuBarItem() {
  let app = NSApplication.shared
  let previous = app.activationPolicy()
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  let a = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 200, height: 100), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  let b = NSWindow(
    contentRect: NSRect(x: 150, y: 150, width: 200, height: 100),
    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
  a.isReleasedWhenClosed = false
  b.isReleasedWhenClosed = false
  defer {
    a.close()
    b.close()
    NSStatusBar.system.removeStatusItem(item)
    app.setActivationPolicy(previous)
  }
  a.orderFront(nil)
  b.orderFront(nil)
  DockPolicy.update(app)
  #expect(app.activationPolicy() == .regular)
  a.close()
  DockPolicy.update(app)
  #expect(app.activationPolicy() == .regular)
  b.miniaturize(nil)
  DockPolicy.update(app)
  #expect(app.activationPolicy() == .regular)
  b.close()
  DockPolicy.update(app)
  #expect(app.activationPolicy() == .accessory)
  #expect(item.isVisible)
  a.orderFront(nil)
  DockPolicy.update(app)
  #expect(app.activationPolicy() == .regular)
}
@Test @MainActor func reopenDoesNotCreateAnotherWindowWhileOneIsVisible() {
  let app = NSApplication.shared
  let controller = AppController(command: nil)
  let before = app.windows.count
  #expect(controller.applicationShouldHandleReopen(app, hasVisibleWindows: true) == false)
  #expect(app.windows.count == before)
}
@Test @MainActor func commonAnnotationToolsEncodeThroughImageIO() throws {
  _ = NSApplication.shared
  let image = CGContext(
    data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 200 * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
  var document = CaptureDocument(image: image, logicalSize: CGSize(width: 200, height: 160))
  for (index, tool) in [
    Tool.pencil, .line, .arrow, .rectangle, .ellipse, .marker, .pixelate, .counter, .text, .invert,
  ].enumerated() {
    var a = Annotation(
      tool: tool,
      points: [
        CGPoint(x: 10 + index * 5, y: 10 + index * 4),
        CGPoint(x: 80 + index * 4, y: 70 + index * 3),
      ], width: tool == .counter ? 24 : 4)
    a.text = "中文 Native"
    a.fontSize = 16
    a.curvedArrow = true
    document.add(a)
  }
  let output = try ImageRenderer.render(document)
  #expect(output.width == 200)
  #expect(output.height == 160)
  for format in ["png", "jpeg", "tiff"] {
    let data = try ImageRenderer.data(output, format: format)
    #expect(NSImage(data: data) != nil)
  }
}

@Test @MainActor func canvasMouseGesturesProduceSelectionAndEditableAnnotations() throws {
  let canvas = CanvasView(frame: nativeFrame())
  let window = CaptureWindow(
    contentRect: CGRect(origin: .zero, size: canvas.bounds.size), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  canvas.edits.groupsByEvent = false
  func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  func drag(_ from: CGPoint, _ to: CGPoint) {
    canvas.edits.beginUndoGrouping()
    canvas.mouseDown(with: event(.leftMouseDown, from))
    canvas.mouseDragged(with: event(.leftMouseDragged, to))
    canvas.mouseUp(with: event(.leftMouseUp, to))
    canvas.edits.endUndoGrouping()
  }
  drag(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 400))
  #expect(canvas.document.selection == CGRect(x: 100, y: 100, width: 400, height: 300))
  for tool in [Tool.arrow, .rectangle, .pencil, .ellipse, .marker, .pixelate, .counter] {
    canvas.setTool(tool)
    drag(CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 250))
  }
  #expect(canvas.document.annotations.count == 7)
  canvas.edits.beginUndoGrouping()
  canvas.beginText(at: CGPoint(x: 120, y: 300))
  canvas.textEditor?.string = "原生中文标注"
  canvas.commitText()
  canvas.edits.endUndoGrouping()
  #expect(canvas.document.annotations.last?.text == "原生中文标注")
  let image = try canvas.rendered()
  #expect(image.width == Int(canvas.document.pixelSelection.width))
  #expect(image.height == Int(canvas.document.pixelSelection.height))
  canvas.edits.undo()
  #expect(canvas.document.annotations.count == 7)
  canvas.edits.redo()
  #expect(canvas.document.annotations.count == 8)
}
