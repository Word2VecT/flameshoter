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

@Test @MainActor func captureRegionHistoryShortcutsDispatchBothDirections() throws {
  let store = Environment.shared.settings
  let previous = store.preferences
  defer { store.update { $0 = previous } }
  store.update {
    $0.shortcuts["TYPE_PREVIOUS_REGION"] = Shortcut(33)
    $0.shortcuts["TYPE_NEXT_REGION"] = Shortcut(30)
    $0.unassignedShortcuts.remove("TYPE_PREVIOUS_REGION")
    $0.unassignedShortcuts.remove("TYPE_NEXT_REGION")
  }
  let canvas = CanvasView(frame: nativeFrame())
  var directions: [Int] = []
  canvas.onRegionHistory = { directions.append($0) }
  for (code, character) in [(UInt16(33), "["), (UInt16(30), "]")] {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, characters: character,
                                               charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    #expect(canvas.handleKey(event))
  }
  #expect(directions == [-1, 1])
}

@Test @MainActor func capturePreviewTracksAnnotationEditsAndSelectionChanges() throws {
  let canvas = CanvasView(frame: nativeFrame())
  let window = CaptureWindow(
    contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  func expectPreview(_ document: CaptureDocument) throws {
    let expected = try ImageRenderer.render(document, includeSelection: false)
    let image = try #require(canvas.selectedImage.image)
    let preview = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(preview.width == expected.width && preview.height == expected.height)
    #expect(preview.dataProvider?.data == expected.dataProvider?.data)
  }
  canvas.setSelection(CGRect(x: 50, y: 50, width: 400, height: 300))
  let annotation = Annotation(
    tool: .rectangle, points: [CGPoint(x: 80, y: 80), CGPoint(x: 200, y: 180)])
  canvas.edits.groupsByEvent = false
  canvas.edits.beginUndoGrouping()
  canvas.add(annotation)
  canvas.edits.endUndoGrouping()
  try expectPreview(canvas.document)
  canvas.setSelection(CGRect(x: 60, y: 60, width: 350, height: 250))
  canvas.setTool(.pencil)
  try expectPreview(canvas.document)
  canvas.selectedID = annotation.id
  canvas.edits.beginUndoGrouping()
  canvas.updateSelected { $0.width = 12 }
  canvas.edits.endUndoGrouping()
  try expectPreview(canvas.document)
  canvas.edits.undo()
  try expectPreview(canvas.document)
  canvas.edits.redo()
  try expectPreview(canvas.document)
  var text = Annotation(tool: .text, points: [CGPoint(x: 90, y: 90)], color: .red)
  text.text = "old text"
  canvas.edits.beginUndoGrouping()
  canvas.add(text)
  canvas.edits.endUndoGrouping()
  canvas.beginText(at: text.points[0], editing: text)
  var whileEditing = canvas.document
  whileEditing.replaceAnnotations(whileEditing.annotations.filter { $0.id != text.id })
  try expectPreview(whileEditing)
  canvas.textEditor?.string = "中文"
  canvas.edits.beginUndoGrouping()
  canvas.commitText()
  canvas.edits.endUndoGrouping()
  try expectPreview(canvas.document)
  func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  for tool in [Tool.rectangle, .pixelate, .invert] {
    canvas.setTool(tool)
    canvas.edits.beginUndoGrouping()
    canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 110, y: 110)))
    for point in [CGPoint(x: 160, y: 145), CGPoint(x: 180, y: 170)] {
      canvas.mouseDragged(with: event(.leftMouseDragged, at: point))
      let preview = try #require(canvas.preview)
      var duringDrag = canvas.document
      duringDrag.replaceAnnotations(duringDrag.annotations + [preview], recordingUndo: false)
      try expectPreview(duringDrag)
    }
    canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 180, y: 170)))
    canvas.edits.endUndoGrouping()
    try expectPreview(canvas.document)
  }
}
@Test func nativeCLIRegionParsing() throws {
  let command = try NativeCommand.parse([
    "gui", "--region", "200x100+20+30", "-c", "--delay", "2000",
  ])
  #expect(command.region == CGRect(x: 20, y: 30, width: 200, height: 100))
  #expect(command.copy)
  #expect(command.delay == 2000)
  #expect(throws: CommandError.self) { try NativeCommand.parse(["gui", "--region", "invalid"]) }
  #expect(throws: CommandError.self) { try NativeCommand.parse(["launcher"]) }
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
  #expect(controller.applicationShouldHandleReopen(app, hasVisibleWindows: false) == false)
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

@Test @MainActor func importedIdleShutdownDoesNotTerminateMenuBarAppWhenLastWindowCloses() throws {
  let app = NSApplication.shared
  let previousPolicy = app.activationPolicy()
  let settings = Environment.shared.settings
  let previousPreferences = settings.preferences
  defer {
    settings.update { $0 = previousPreferences }
    app.setActivationPolicy(previousPolicy)
  }
  let legacy = try SettingsStore.parseINI(
    "[General]\nautoCloseIdleDaemon=true\ndisabledTrayIcon=false\n")
  settings.update { $0 = legacy }
  let controller = AppController(command: nil)
  let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 200, height: 100), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.orderFront(nil)
  #expect(!controller.shouldQuitWhenIdle())
  window.close()
  DockPolicy.update(app)
  #expect(app.activationPolicy() == .accessory)
  #expect(!controller.shouldQuitWhenIdle())
  settings.set("disabledTrayIcon", true)
  #expect(controller.shouldQuitWhenIdle())
  settings.set("autoCloseIdleDaemon", false)
  #expect(!controller.shouldQuitWhenIdle())
}

@Test @MainActor func dragStartAndThinSelectionsHaveValidCursorAndViewRectangles() {
  let canvas = CanvasView(frame: nativeFrame())
  let window = CaptureWindow(
    contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  let event = NSEvent.mouseEvent(
    with: .leftMouseDown, location: canvas.convert(CGPoint(x: 100, y: 100), to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
    eventNumber: 0, clickCount: 1, pressure: 1)!
  canvas.mouseDown(with: event)
  #expect(canvas.document.selection?.size == CGSize(width: 1, height: 1))
  canvas.resetCursorRects()
  for size in [
    CGSize(width: 1, height: 1), CGSize(width: 1, height: 200), CGSize(width: 200, height: 1),
    CGSize(width: 4, height: 4), CGSize(width: 16, height: 16), CGSize(width: 100, height: 80),
  ] {
    canvas.setSelection(CGRect(origin: CGPoint(x: 100, y: 100), size: size))
    canvas.resetCursorRects()
    for frame in [canvas.imageClip.frame, canvas.dimensions.frame] {
      #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
      #expect(frame.size.width.isFinite && frame.size.height.isFinite)
    }
    #expect(canvas.imageClip.frame.size.width >= 0)
    #expect(canvas.imageClip.frame.size.height >= 0)
    #expect(canvas.dimensions.frame.size.width >= 0)
    #expect(canvas.dimensions.frame.size.height >= 0)
  }
}

@Test func captureToolbarMatchesOriginalFlameshotCoordinates() throws {
  struct Reference: Decodable {
    struct Case: Decodable {
      let bounds: [Int]
      let selection: [Int]
      let baseSize: Int
      let positions: [[Int]]
    }
    let cases: [Case]
  }
  let url = try #require(
    Bundle.module.url(
      forResource: "flameshot-toolbar", withExtension: "json", subdirectory: "Fixtures"))
  let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  func rect(_ values: [Int]) -> CGRect {
    CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }
  for sample in reference.cases {
    let frames = CaptureToolbarLayout.frames(
      count: sample.positions.count, selection: rect(sample.selection),
      bounds: rect(sample.bounds), baseSize: sample.baseSize)
    #expect(frames.map { [Int($0.minX), Int($0.minY)] } == sample.positions)
  }
}

@Test @MainActor func captureToolbarButtonsAreDirectlyClickableAndRespectConfiguration() throws {
  let settings = Environment.shared.settings
  let previous = settings.preferences
  defer { settings.update { $0 = previous } }
  settings.update { $0.tools = [.pin, .save, .invert, .line, .pencil, .accept] }
  let canvas = CanvasView(frame: nativeFrame())
  let window = CaptureWindow(
    contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  canvas.setSelection(CGRect(x: 200, y: 200, width: 400, height: 250))
  let toolbar = CaptureToolbar(canvas: canvas)
  defer { toolbar.close() }
  func buttons(_ view: NSView) -> [ActionButton] {
    (view as? ActionButton).map { [$0] } ?? view.subviews.flatMap(buttons)
  }
  let controls = buttons(toolbar.root)
  let expected = [Tool.pencil, .line, .invert, .save, .pin].map(toolTitle)
  #expect(
    controls.compactMap { $0.accessibilityLabel() }.filter { expected.contains($0) } == expected)
  for button in controls {
    let rect = button.convert(button.bounds, to: canvas)
    #expect(rect.width >= 16 && rect.height >= 16)
    #expect(canvas.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)))
    let point = canvas.superview!.convert(CGPoint(x: rect.midX, y: rect.midY), from: canvas)
    let hit = canvas.hitTest(point)
    #expect(hit === button)
  }
  #expect(
    canvas.hitTest(canvas.superview!.convert(CGPoint(x: 300, y: 300), from: canvas)) === canvas)
  let line = try #require(controls.first { $0.accessibilityLabel() == toolTitle(.line) })
  line.performClick(nil)
  #expect(canvas.tool == .line)
  #expect(line.state == .on)
  let invert = try #require(controls.first { $0.accessibilityLabel() == toolTitle(.invert) })
  invert.performClick(nil)
  #expect(canvas.tool == .invert)
  toolbar.close()
  let outputToolbar = CaptureToolbar(
    canvas: canvas, command: try NativeCommand.parse(["gui", "--raw"]))
  defer { outputToolbar.close() }
  let outputLabels = buttons(outputToolbar.root).compactMap { $0.accessibilityLabel() }
  #expect(outputLabels.contains(toolTitle(.accept)))
  #expect(!outputLabels.contains(toolTitle(.save)))
  #expect(!outputLabels.contains(toolTitle(.pin)))
}

@Test @MainActor func captureToolbarEdgesActivateButtonsWithoutReplacingTheSelection() throws {
  let settings = Environment.shared.settings
  let previous = settings.preferences
  defer { settings.update { $0 = previous } }
  settings.update {
    $0.tools = [.pencil, .line, .undo]
    $0.values["showSidePanelButton"] = "true"
  }
  let canvas = CanvasView(frame: nativeFrame())
  let window = CaptureWindow(
    contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  let selection = CGRect(x: 160, y: 130, width: 320, height: 220)
  canvas.setSelection(selection)
  let toolbar = CaptureToolbar(canvas: canvas)
  defer { toolbar.close() }
  let button = try #require(toolbar.button(for: .pencil))
  var ancestor: NSView? = button
  while let view = ancestor, !(view is NSGlassEffectView) { ancestor = view.superview }
  let glass = try #require(ancestor as? NSGlassEffectView)
  let frame = glass.convert(glass.bounds, to: canvas)
  let points = [
    CGPoint(x: frame.minX + 1, y: frame.midY),
    CGPoint(x: frame.maxX - 1, y: frame.midY),
    CGPoint(x: frame.midX, y: frame.minY + 1),
    CGPoint(x: frame.midX, y: frame.maxY - 1),
    CGPoint(x: frame.minX - 3, y: frame.midY),
    CGPoint(x: frame.maxX + 3, y: frame.midY),
    CGPoint(x: frame.midX, y: frame.minY - 3),
    CGPoint(x: frame.midX, y: frame.maxY + 3),
    CGPoint(x: frame.minX + 1, y: frame.minY + 1),
    CGPoint(x: frame.maxX - 1, y: frame.maxY - 1),
  ]
  for point in points {
    #expect(canvas.bounds.contains(point))
    let hit = canvas.hitTest(canvas.superview!.convert(point, from: canvas))
    try #require(hit === button)
    canvas.setTool(nil)
    button.performClick(nil)
    #expect(canvas.tool == .pencil)
    #expect(canvas.document.selection == selection)
  }
  let line = try #require(toolbar.button(for: .line))
  var lineAncestor: NSView? = line
  while let view = lineAncestor, !(view is NSGlassEffectView) { lineAncestor = view.superview }
  let lineGlass = try #require(lineAncestor as? NSGlassEffectView)
  let lineFrame = lineGlass.convert(lineGlass.bounds, to: canvas)
  #expect(abs(frame.midY - lineFrame.midY) < 1)
  let middle = (frame.maxX + lineFrame.minX) / 2
  let nearPencil = CGPoint(x: middle - 0.5, y: frame.midY)
  let nearLine = CGPoint(x: middle + 0.5, y: frame.midY)
  #expect(canvas.hitTest(canvas.superview!.convert(nearPencil, from: canvas)) === button)
  #expect(canvas.hitTest(canvas.superview!.convert(nearLine, from: canvas)) === line)
  let inspector = try #require(
    toolbar.root.controls.first {
      $0.accessibilityLabel() == localized("Tool settings", "工具设置")
    })
  var inspectorAncestor: NSView? = inspector
  while let view = inspectorAncestor, !(view is NSGlassEffectView) {
    inspectorAncestor = view.superview
  }
  let inspectorGlass = try #require(inspectorAncestor as? NSGlassEffectView)
  let inspectorFrame = inspectorGlass.convert(inspectorGlass.bounds, to: canvas)
  let inspectorEdge = CGPoint(x: inspectorFrame.maxX + 3, y: inspectorFrame.midY)
  #expect(canvas.hitTest(canvas.superview!.convert(inspectorEdge, from: canvas)) === inspector)
  let outside = CGPoint(x: 80, y: 80)
  #expect(canvas.hitTest(canvas.superview!.convert(outside, from: canvas)) === canvas)
  let undo = try #require(toolbar.button(for: .undo))
  #expect(!undo.isEnabled)
  let undoPoint = undo.convert(CGPoint(x: undo.bounds.midX, y: undo.bounds.midY), to: canvas)
  #expect(canvas.hitTest(canvas.superview!.convert(undoPoint, from: canvas)) === toolbar.root)
  let disabledDown = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseDown, location: canvas.convert(undoPoint, to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
      clickCount: 1, pressure: 1))
  toolbar.root.mouseDown(with: disabledDown)
  toolbar.root.mouseUp(with: disabledDown)
  #expect(canvas.document.selection == selection)
  let down = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseDown, location: canvas.convert(outside, to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
      clickCount: 1, pressure: 1))
  canvas.mouseDown(with: down)
  #expect(canvas.document.selection?.size == CGSize(width: 1, height: 1))
}

@Test @MainActor func settingsFitMinimumWindowAndUseCompactToolColumns() throws {
  let settings = Environment.shared.settings
  let previous = settings.preferences
  defer { settings.update { $0 = previous } }
  for language in ["zh_CN", "en"] {
    settings.set("uiLanguage", language)
    let controller = PreferencesController()
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 720, height: 540))
    let tabs = try #require(window.contentViewController as? NSTabViewController)
    for index in tabs.tabViewItems.indices {
      tabs.selectedTabViewItemIndex = index
      tabs.view.layoutSubtreeIfNeeded()
      let scroll = try #require(tabs.tabViewItems[index].viewController?.view as? NSScrollView)
      scroll.layoutSubtreeIfNeeded()
      let document = try #require(scroll.documentView)
      func controls(_ view: NSView) -> [NSControl] {
        (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(controls)
      }
      for control in controls(document) {
        let rect = control.convert(control.bounds, to: document)
        #expect(
          rect.minX >= -1 && rect.maxX <= document.bounds.width + 1,
          "\(language), page \(index): control \(rect) exceeds \(document.bounds)")
      }
      if index == 0 || index == 2 {
        #expect(
          document.frame.height <= scroll.contentView.bounds.height + 1,
          "General and Toolbar should fit without scrolling")
      }
      if index == 0 {
        let restart = try #require(
          controls(document).compactMap { $0 as? ActionButton }
            .first { $0.title == localized("Restart Flameshoter", "重新启动 Flameshoter") })
        #expect(restart.frame.width < 260)
      }
    }
    window.close()
  }
}

@Test @MainActor func systemShareUsesRenderedSelectionAndCompletesOnlyAfterSharing() throws {
  let canvas = CanvasView(frame: nativeFrame())
  canvas.setSelection(CGRect(x: 100, y: 100, width: 200, height: 120))
  canvas.add(
    Annotation(
      tool: .rectangle,
      points: [CGPoint(x: 120, y: 120), CGPoint(x: 220, y: 180)], color: .red, width: 4))
  let image = try canvas.rendered()
  let controller = CaptureSharing(image: image)
  let sharedImage = try #require(
    controller.item.cgImage(forProposedRect: nil, context: nil, hints: nil))
  #expect(sharedImage.width == image.width && sharedImage.height == image.height)
  #expect(try ImageRenderer.data(sharedImage) == ImageRenderer.data(image))
  let service = NSSharingService(
    title: "Test", image: NSImage(size: NSSize(width: 16, height: 16)),
    alternateImage: nil, handler: {})
  var began = 0
  var finished = 0
  controller.onBegin = { began += 1 }
  controller.onFinish = { result in
    finished += 1
    #expect((try? result.get()) == true)
  }
  #expect(controller.sharingServicePicker(controller.picker, delegateFor: service) === controller)
  controller.sharingServicePicker(controller.picker, didChoose: service)
  #expect(began == 1 && finished == 0)
  // Dismissing the picker after choosing a service must not cancel the service.
  controller.sharingServicePicker(controller.picker, didChoose: nil)
  #expect(finished == 0)
  controller.sharingService(service, didShareItems: [controller.item])
  controller.sharingService(service, didShareItems: [controller.item])
  #expect(finished == 1)
  #expect(controller.picker.delegate == nil)
}

@Test @MainActor func systemShareCancellationAndFailurePreserveTheCapture() throws {
  let canvas = CanvasView(frame: nativeFrame())
  canvas.setSelection(CGRect(x: 100, y: 100, width: 200, height: 120))
  let original = canvas.document.selection
  let image = try canvas.rendered()
  let cancelled = CaptureSharing(image: image)
  var cancelledCount = 0
  cancelled.onFinish = { result in
    #expect((try? result.get()) == false)
    cancelledCount += 1
  }
  cancelled.sharingServicePicker(cancelled.picker, didChoose: nil)
  cancelled.sharingServicePicker(cancelled.picker, didChoose: nil)
  #expect(cancelledCount == 1)
  let failed = CaptureSharing(image: image)
  let error = CocoaError(.userCancelled)
  var reported: NSError?
  failed.onFinish = { if case .failure(let error) = $0 { reported = error as NSError } }
  let service = NSSharingService(
    title: "Test", image: NSImage(size: NSSize(width: 16, height: 16)),
    alternateImage: nil, handler: {})
  failed.sharingServicePicker(failed.picker, didChoose: service)
  failed.sharingService(service, didFailToShareItems: [failed.item], error: error)
  #expect(reported?.domain == NSCocoaErrorDomain && reported?.code == NSUserCancelledError)
  #expect(canvas.document.selection == original)
}

@Test @MainActor func shareTooltipUsesTheCurrentShortcutWithoutEllipsis() throws {
  let settings = Environment.shared.settings
  let previous = settings.preferences
  defer { settings.update { $0 = previous } }
  settings.update {
    $0.tools = [.share]
    $0.shortcuts.removeValue(forKey: "TYPE_SHARE")
    $0.unassignedShortcuts.remove("TYPE_SHARE")
  }
  let canvas = CanvasView(frame: nativeFrame())
  let toolbar = CaptureToolbar(canvas: canvas)
  defer { toolbar.close() }
  let share = try #require(toolbar.button(for: .share))
  for (language, name) in [("zh_CN", "分享"), ("en", "Share")] {
    settings.set("uiLanguage", language)
    toolbar.refresh()
    #expect(share.accessibilityLabel() == name)
    #expect(share.toolTip == name + "  ⇧⌘S")
  }
  settings.update { $0.shortcuts["TYPE_SHARE"] = Shortcut(1, [.command, .option]) }
  toolbar.refresh()
  #expect(share.toolTip == "Share  ⌥⌘S")
  settings.update { $0.unassignedShortcuts.insert("TYPE_SHARE") }
  toolbar.refresh()
  #expect(share.toolTip == "Share")
}
