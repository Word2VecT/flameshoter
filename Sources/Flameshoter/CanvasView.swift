// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

@MainActor final class AnnotationLayer: PassiveView {
  weak var canvas: CanvasView?
  override func draw(_ dirtyRect: NSRect) {
    guard let canvas else { return }
    if let selected = canvas.selectedAnnotation {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let path = NSBezierPath(rect: selected.bounds.insetBy(dx: -4, dy: -4))
      path.lineWidth = 1
      path.setLineDash([4, 3], count: 2, phase: 0)
      path.stroke()
    }
  }
}
@MainActor final class PixelImageView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.current?.imageInterpolation = .none
    super.draw(dirtyRect)
  }
}
@MainActor final class PassiveImageView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class CanvasView: NSView, NSTextViewDelegate {
  var document: CaptureDocument
  var preview: Annotation?
  var tool: Tool?
  var selectedID: UUID?
  var selectedAnnotation: Annotation? { document.annotations.first { $0.id == selectedID } }
  let edits = UndoManager()
  override var undoManager: UndoManager? { edits }
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }
  var onAction: ((Tool) -> Void)?
  var onChange: (() -> Void)?
  var onInteract: (() -> Bool)?
  var onRegionSettled: (() -> Void)?
  var onInspector: (() -> Void)?
  let frost = PassiveFrost()
  let selectionGlass = PassiveGlass()
  let glassContent = PassiveView()
  let drawing = AnnotationLayer()
  let selectedImage = PassiveImageView()
  let imageClip = PassiveView()
  let dimensions = NSTextField(labelWithString: "")
  let magnifier = PassiveGlass()
  let magnifierImage = PixelImageView()
  var handles: [PassiveImageView] = []
  var textEditor: NSTextView?
  private var textDraft: Annotation?
  private var editingTextID: UUID?
  private var tracking: NSTrackingArea?
  private var dimensionsTimer: Timer?
  private var lastPresentation: CGRect?
  private var operation: DragOperation?
  private var originalAnnotations: [Annotation]?
  private var prefs: Preferences { Environment.shared.preferences }
  private enum DragOperation {
    case region(CGPoint)
    case moveRegion(CGPoint, CGRect)
    case resize(CGPoint, CGRect, Int)
    case drawing
    case annotation(CGPoint, Annotation)
  }
  init(frame: CapturedScreen) {
    document = CaptureDocument(
      image: frame.image, logicalSize: frame.logicalSize,
      undoLimit: Environment.shared.preferences.integer("undoLimit"))
    super.init(frame: CGRect(origin: .zero, size: frame.logicalSize))
    edits.levelsOfUndo = prefs.integer("undoLimit")
    frost.frame = bounds
    frost.autoresizingMask = [.width, .height]
    frost.material = .fullScreenUI
    frost.blendingMode = .withinWindow
    frost.state = .active
    frost.alphaValue =
      NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
      ? 1 : CGFloat(prefs.integer("contrastOpacity")) / 255
    frost.setAccessibilityElement(false)
    addSubview(frost)
    selectionGlass.style = .clear
    selectionGlass.cornerRadius = 12
    selectionGlass.contentView = glassContent
    selectionGlass.isHidden = true
    selectionGlass.setAccessibilityElement(false)
    if !prefs.bool("useSystemAccentColor") {
      selectionGlass.tintColor = prefs.color("uiColor").color
    }
    addSubview(selectionGlass)
    glassContent.clipsToBounds = true
    imageClip.wantsLayer = true
    imageClip.layer?.masksToBounds = true
    imageClip.layer?.cornerRadius = 10
    selectedImage.image = NSImage(cgImage: document.image, size: document.logicalSize)
    selectedImage.imageScaling = .scaleAxesIndependently
    imageClip.addSubview(selectedImage)
    glassContent.addSubview(imageClip)
    drawing.canvas = self
    glassContent.addSubview(drawing)
    dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    dimensions.textColor = .labelColor
    dimensions.alignment = .right
    dimensions.setAccessibilityLabel(localized("Capture region dimensions", "截图选区尺寸"))
    glassContent.addSubview(dimensions)
    for _ in 0..<8 {
      let handle = PassiveImageView()
      handle.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
      handle.contentTintColor = .controlAccentColor
      handle.imageScaling = .scaleProportionallyUpOrDown
      handle.setAccessibilityElement(false)
      handle.isHidden = true
      handles.append(handle)
      addSubview(handle)
    }
    magnifier.style = .regular
    magnifier.cornerRadius = prefs.bool("squareMagnifier") ? 12 : 64
    let magnifierContent = PassiveView()
    magnifier.contentView = magnifierContent
    magnifierImage.frame = NSRect(x: 6, y: 6, width: 116, height: 116)
    magnifierImage.imageScaling = .scaleAxesIndependently
    magnifierContent.addSubview(magnifierImage)
    let crosshair = PassiveImageView(frame: NSRect(x: 57, y: 57, width: 14, height: 14))
    crosshair.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    crosshair.contentTintColor = .labelColor
    magnifierContent.addSubview(crosshair)
    magnifier.isHidden = true
    magnifier.setAccessibilityElement(false)
    addSubview(magnifier)
    refresh()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func draw(_ dirtyRect: NSRect) {
    NSImage(cgImage: document.image, size: document.logicalSize).draw(
      in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
  }
  override func layout() {
    super.layout()
    refreshPresentation()
  }
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
      owner: self, userInfo: nil)
    addTrackingArea(tracking!)
    super.updateTrackingAreas()
  }
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: tool == .moveSelection ? .openHand : .crosshair)
    if let r = document.selection {
      if tool == nil || tool == .moveSelection, r.width > 16, r.height > 16 {
        addCursorRect(r.insetBy(dx: 8, dy: 8), cursor: .openHand)
      }
      for x in [r.minX, r.maxX] {
        addCursorRect(
          CGRect(x: x - 6, y: r.minY, width: 12, height: r.height), cursor: .resizeLeftRight)
      }
      for y in [r.minY, r.maxY] {
        addCursorRect(
          CGRect(x: r.minX, y: y - 6, width: r.width, height: 12), cursor: .resizeUpDown)
      }
    }
  }
  func refresh() {
    refreshPresentation()
    redrawContent()
    onChange?()
    window?.invalidateCursorRects(for: self)
  }
  private func redrawContent() {
    var composed = document
    if let editingTextID {
      composed.replaceAnnotations(
        composed.annotations.filter { $0.id != editingTextID }, recordingUndo: false)
    }
    if let preview {
      composed.replaceAnnotations(composed.annotations + [preview], recordingUndo: false)
    }
    if let image = try? ImageRenderer.render(composed, includeSelection: false) {
      selectedImage.image = NSImage(cgImage: image, size: document.logicalSize)
    }
    drawing.needsDisplay = true
  }
  private func refreshPresentation() {
    frost.alphaValue =
      NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
      ? 1 : CGFloat(prefs.integer("contrastOpacity")) / 255
    selectionGlass.tintColor =
      prefs.bool("useSystemAccentColor") ? nil : prefs.color("uiColor").color
    magnifier.cornerRadius = prefs.bool("squareMagnifier") ? 12 : 64
    edits.levelsOfUndo = prefs.integer("undoLimit")
    let r = document.selection
    selectionGlass.isHidden = r == nil || r!.isEmpty
    if let r, !r.isEmpty {
      selectionGlass.frame = r
      glassContent.frame = CGRect(origin: .zero, size: r.size)
      let inset = min(2, min(r.width, r.height) / 2)
      imageClip.frame = selectionGlass.bounds.insetBy(dx: inset, dy: inset)
      selectedImage.frame = CGRect(
        x: -r.minX - inset, y: -r.minY - inset, width: bounds.width, height: bounds.height)
      drawing.frame = CGRect(x: -r.minX, y: -r.minY, width: bounds.width, height: bounds.height)
      let points = [
        CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
        CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY),
        CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
      ]
      for (handle, point) in zip(handles, points) {
        handle.frame = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        handle.isHidden = tool?.isDrawing == true
      }
      updateDimensions(r)
    } else {
      for handle in handles { handle.isHidden = true }
    }
    if r != lastPresentation || frost.maskImage?.size != bounds.size {
      let aperture = r
      let size = bounds.size
      let radius = selectionGlass.cornerRadius
      frost.maskImage = NSImage(size: size, flipped: true) { rect in
        let path = NSBezierPath(rect: rect)
        if let aperture { path.appendRoundedRect(aperture, xRadius: radius, yRadius: radius) }
        path.windingRule = .evenOdd
        NSColor.white.setFill()
        path.fill()
        return true
      }
      lastPresentation = r
    }
  }
  private func updateDimensions(_ rect: CGRect) {
    let position = prefs.integer("showSelectionGeometry")
    dimensions.isHidden = position == 0 || rect.width < 110 || rect.height < 32
    dimensionsTimer?.invalidate()
    guard !dimensions.isHidden else { return }
    dimensions.stringValue =
      "\(Int(rect.width*document.scale)) × \(Int(rect.height*document.scale))  ·  \(Int(rect.minX*document.scale)), \(Int(rect.minY*document.scale))"
    let width = min(280, rect.width - 16)
    let height: CGFloat = 20
    var origin = CGPoint(x: 8, y: rect.height - height - 6)
    switch position {
    case 1:
      origin = CGPoint(x: 8, y: 6)
      dimensions.alignment = .left
    case 2:
      origin = CGPoint(x: rect.width - width - 8, y: 6)
      dimensions.alignment = .right
    case 3:
      origin = CGPoint(x: 8, y: rect.height - height - 6)
      dimensions.alignment = .left
    case 5:
      origin = CGPoint(x: (rect.width - width) / 2, y: (rect.height - height) / 2)
      dimensions.alignment = .center
    default:
      origin.x = rect.width - width - 8
      dimensions.alignment = .right
    }
    dimensions.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
    let duration = prefs.integer("showSelectionGeometryHideTime")
    if duration > 0 {
      dimensionsTimer = Timer.scheduledTimer(
        withTimeInterval: Double(duration) / 1000, repeats: false
      ) { [weak self] _ in MainActor.assumeIsolated { self?.dimensions.isHidden = true } }
    }
  }
  func setSelection(_ rect: CGRect?) {
    document.selection = rect.map { $0.standardized.intersection(bounds) }.flatMap {
      $0.isEmpty || $0.isNull ? nil : $0
    }
    refresh()
  }
  func setTool(_ tool: Tool?) {
    commitText()
    self.tool = self.tool == tool ? nil : tool
    selectedID = nil
    refresh()
  }
  func setAnnotations(_ annotations: [Annotation], name: String = "") {
    let previous = document.annotations
    guard annotations != previous else { return }
    edits.registerUndo(withTarget: self) { $0.setAnnotations(previous, name: name) }
    edits.setActionName(name)
    document.replaceAnnotations(annotations, recordingUndo: false)
    refresh()
  }
  func add(_ annotation: Annotation) {
    setAnnotations(document.annotations + [annotation], name: toolTitle(annotation.tool))
  }
  func updateSelected(_ body: (inout Annotation) -> Void) {
    guard let index = document.annotations.firstIndex(where: { $0.id == selectedID }) else {
      return
    }
    var all = document.annotations
    body(&all[index])
    setAnnotations(all, name: localized("Edit annotation", "编辑标注"))
  }
  func applyStyle(_ body: (inout Annotation) -> Void) {
    updateSelected(body)
    if var draft = textDraft {
      body(&draft)
      textDraft = draft
      if let textEditor { configureText(textEditor, annotation: draft) }
    }
    onChange?()
  }
  func deleteSelected() {
    guard let selectedID else { return }
    setAnnotations(
      document.annotations.filter { $0.id != selectedID },
      name: localized("Delete annotation", "删除标注"))
    self.selectedID = nil
    refresh()
  }
  func moveLayer(_ offset: Int) {
    guard let index = document.annotations.firstIndex(where: { $0.id == selectedID }),
      document.annotations.indices.contains(index + offset)
    else { return }
    var all = document.annotations
    all.swapAt(index, index + offset)
    setAnnotations(all, name: localized("Reorder annotation", "调整标注层级"))
  }
  func rendered() throws -> CGImage {
    commitText()
    return try ImageRenderer.render(document)
  }
  private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
  private func bounded(_ point: CGPoint) -> CGPoint {
    CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
  }
  private func edges(_ point: CGPoint, _ r: CGRect) -> Int {
    guard r.insetBy(dx: -8, dy: -8).contains(point) else { return 0 }
    var edges = 0
    if abs(point.x - r.minX) <= 8 { edges |= 1 }
    if abs(point.x - r.maxX) <= 8 { edges |= 2 }
    if abs(point.y - r.minY) <= 8 { edges |= 4 }
    if abs(point.y - r.maxY) <= 8 { edges |= 8 }
    return edges
  }
  private func newAnnotation(_ tool: Tool, _ point: CGPoint) -> Annotation {
    var a = Annotation(
      tool: tool, points: [point, point], color: prefs.color("drawColor"),
      width: prefs.toolSize(tool))
    a.font = prefs.string("fontFamily")
    a.fontSize = CGFloat(prefs.integer("drawFontSize"))
    a.bold = prefs.bool("textBold")
    a.italic = prefs.bool("textItalic")
    a.underline = prefs.bool("textUnderline")
    a.strike = prefs.bool("textStrike")
    a.alignment = prefs.integer("textAlignment")
    a.reverseArrow = prefs.bool("reverseArrow")
    a.curvedArrow = prefs.integer("arrowStyle") == 1
    a.outlinedCounter = prefs.bool("drawCircleCounterOutline")
    a.traditionalPixelation = prefs.bool("insecurePixelate")
    a.filled = prefs.bool("filledShapes")
    a.number = (document.annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    return a
  }
  override func mouseDown(with event: NSEvent) {
    commitText()
    if onInteract?() == false { return }
    window?.makeFirstResponder(self)
    let p = bounded(point(event))
    if event.clickCount == 2, tool == .select, let text = document.annotation(at: p),
      text.tool == .text
    {
      beginText(at: text.points[0], editing: text)
      return
    }
    if event.clickCount == 2, prefs.bool("copyOnDoubleClick"), document.selection != nil {
      onAction?(.copy)
      return
    }
    guard let r = document.selection else {
      operation = .region(p)
      setSelection(CGRect(origin: p, size: CGSize(width: 1, height: 1)))
      return
    }
    let edge = edges(p, r)
    if edge != 0 && (tool == nil || tool == .moveSelection || tool == .select) {
      operation = .resize(p, r, edge)
      return
    }
    if !r.contains(p) {
      operation = .region(p)
      setSelection(CGRect(origin: p, size: CGSize(width: 1, height: 1)))
      return
    }
    if tool == .select {
      selectedID = document.annotation(at: p)?.id
      if let a = selectedAnnotation {
        originalAnnotations = document.annotations
        operation = .annotation(p, a)
      }
      refresh()
      return
    }
    guard let tool, tool.isDrawing else {
      operation = .moveRegion(p, r)
      NSCursor.closedHand.set()
      return
    }
    if tool == .text {
      beginText(at: p)
      return
    }
    if tool == .counter {
      add(newAnnotation(tool, p))
      return
    }
    preview = newAnnotation(tool, p)
    operation = .drawing
    refresh()
  }
  override func mouseDragged(with event: NSEvent) {
    let p = bounded(point(event))
    switch operation {
    case .region(let start):
      var end = p
      if event.modifierFlags.contains(.shift) {
        let length = min(abs(p.x - start.x), abs(p.y - start.y))
        end = CGPoint(
          x: start.x + (p.x >= start.x ? length : -length),
          y: start.y + (p.y >= start.y ? length : -length))
      }
      setSelection(
        CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized
      )
    case .moveRegion(let start, let rect):
      var moved = rect.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
      moved.origin.x = max(0, min(bounds.width - moved.width, moved.minX))
      moved.origin.y = max(0, min(bounds.height - moved.height, moved.minY))
      setSelection(moved)
    case .resize(let start, let rect, let edges):
      var x1 = rect.minX
      var x2 = rect.maxX
      var y1 = rect.minY
      var y2 = rect.maxY
      if edges & 1 != 0 { x1 += p.x - start.x }
      if edges & 2 != 0 { x2 += p.x - start.x }
      if edges & 4 != 0 { y1 += p.y - start.y }
      if edges & 8 != 0 { y2 += p.y - start.y }
      setSelection(CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1).standardized)
    case .drawing:
      guard var a = preview, let first = a.points.first else { return }
      if [.pencil, .marker].contains(a.tool) {
        a.points.append(p)
      } else {
        var end = p
        if event.modifierFlags.contains(.shift) {
          if [.line, .arrow].contains(a.tool) {
            let angle = (atan2(p.y - first.y, p.x - first.x) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(p.x - first.x, p.y - first.y)
            end = CGPoint(x: first.x + cos(angle) * length, y: first.y + sin(angle) * length)
          } else {
            let side = min(abs(p.x - first.x), abs(p.y - first.y))
            end = CGPoint(
              x: first.x + (p.x > first.x ? side : -side),
              y: first.y + (p.y > first.y ? side : -side))
          }
        }
        a.points = [first, end]
      }
      preview = a
      redrawContent()
    case .annotation(let start, let original):
      guard let originalAnnotations else { return }
      var a = original
      a.move(by: CGSize(width: p.x - start.x, height: p.y - start.y))
      document.replaceAnnotations(
        originalAnnotations.map { $0.id == a.id ? a : $0 }, recordingUndo: false)
      redrawContent()
    case nil: break
    }
  }
  override func mouseUp(with event: NSEvent) {
    if case .drawing = operation, let a = preview,
      [.pencil, .marker].contains(a.tool) || a.bounds.width > 0.5 || a.bounds.height > 0.5
    {
      add(a)
    }
    if case .annotation = operation, let originalAnnotations {
      let changed = document.annotations
      document.replaceAnnotations(originalAnnotations, recordingUndo: false)
      setAnnotations(changed, name: localized("Move annotation", "移动标注"))
    }
    let settled: Bool
    switch operation {
    case .region, .moveRegion, .resize: settled = true
    default: settled = false
    }
    preview = nil
    originalAnnotations = nil
    operation = nil
    refresh()
    if settled { onRegionSettled?() }
  }
  override func rightMouseDown(with event: NSEvent) {
    commitText()
    if let a = document.annotation(at: point(event)) {
      selectedID = a.id
      refresh()
    }
    onInspector?()
  }
  override func mouseMoved(with event: NSEvent) {
    guard prefs.bool("showMagnifier"), tool?.isDrawing != true else {
      magnifier.isHidden = true
      return
    }
    let p = point(event)
    let scale = document.scale
    let side = 17
    let x = min(max(0, Int(p.x * scale) - side / 2), document.image.width - side)
    let y = min(max(0, Int(p.y * scale) - side / 2), document.image.height - side)
    guard
      let image = document.image.cropping(
        to: CGRect(
          x: max(0, x), y: max(0, y), width: min(side, document.image.width),
          height: min(side, document.image.height)))
    else { return }
    magnifierImage.image = NSImage(cgImage: image, size: CGSize(width: side, height: side))
    magnifier.frame = CGRect(
      x: min(bounds.width - 140, p.x + 24), y: min(bounds.height - 140, p.y + 24), width: 128,
      height: 128)
    magnifier.isHidden = false
  }
  override func mouseExited(with event: NSEvent) { magnifier.isHidden = true }
  override func scrollWheel(with event: NSEvent) {
    guard let tool, tool.isDrawing else { return }
    let n = min(500, max(1, prefs.integer(tool.sizeKey) + (event.scrollingDeltaY > 0 ? 1 : -1)))
    Environment.shared.settings.set(tool.sizeKey, n)
    updateSelected { if $0.tool == .text { $0.fontSize = Double(n) } else { $0.width = Double(n) } }
    onChange?()
  }
  private func configureText(_ view: NSTextView, annotation a: Annotation) {
    let base =
      a.font.isEmpty
      ? NSFont.systemFont(ofSize: a.fontSize)
      : NSFont(name: a.font, size: a.fontSize) ?? NSFontManager.shared.font(
        withFamily: a.font, traits: [], weight: 5, size: a.fontSize)
        ?? .systemFont(ofSize: a.fontSize)
    var traits: NSFontTraitMask = []
    if a.bold { traits.insert(.boldFontMask) }
    if a.italic { traits.insert(.italicFontMask) }
    let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = a.alignment == 1 ? .center : a.alignment == 2 ? .right : .left
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: a.color.color, .paragraphStyle: paragraph,
      .underlineStyle: a.underline ? NSUnderlineStyle.single.rawValue : 0,
      .strikethroughStyle: a.strike ? NSUnderlineStyle.single.rawValue : 0,
    ]
    view.font = font
    view.textColor = a.color.color
    view.defaultParagraphStyle = paragraph
    view.alignment = paragraph.alignment
    view.textStorage?.setAttributes(
      attributes, range: NSRange(location: 0, length: (view.string as NSString).length))
    view.typingAttributes = attributes
  }
  func beginText(at point: CGPoint, editing: Annotation? = nil) {
    var a = editing ?? newAnnotation(.text, point)
    if editing == nil {
      a.points = [
        point,
        CGPoint(
          x: min(bounds.width, point.x + max(180, document.selection?.width ?? 200) / 2), y: point.y
        ),
      ]
    }
    textDraft = a
    editingTextID = editing?.id
    redrawContent()
    let view = NSTextView(
      frame: CGRect(
        x: point.x, y: point.y, width: max(120, a.bounds.width), height: max(64, a.fontSize * 2)))
    view.isRichText = false
    view.drawsBackground = false
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.font =
      a.font.isEmpty
      ? .systemFont(ofSize: a.fontSize)
      : NSFont(name: a.font, size: a.fontSize) ?? .systemFont(ofSize: a.fontSize)
    view.textColor = a.color.color
    view.insertionPointColor = .controlAccentColor
    view.string = a.text
    configureText(view, annotation: a)
    view.delegate = self
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.allowsUndo = true
    addSubview(view)
    textEditor = view
    window?.makeFirstResponder(view)
  }
  func textDidChange(_ notification: Notification) {
    guard let editor = textEditor else { return }
    editor.layoutManager?.ensureLayout(for: editor.textContainer!)
    let height = editor.layoutManager?.usedRect(for: editor.textContainer!).height ?? 50
    editor.setFrameSize(CGSize(width: editor.frame.width, height: max(64, height + 20)))
  }
  func commitText() {
    guard let editor = textEditor, var a = textDraft else { return }
    a.text = editor.string
    a.points = [a.points[0], CGPoint(x: a.points[0].x + editor.frame.width, y: a.points[0].y)]
    editor.removeFromSuperview()
    textEditor = nil
    textDraft = nil
    window?.makeFirstResponder(self)
    let old = editingTextID
    editingTextID = nil
    let empty = a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if let old {
      setAnnotations(
        document.annotations.filter { $0.id != old } + (empty ? [] : [a]),
        name: localized("Edit text", "编辑文字"))
    } else if !empty {
      add(a)
    }
    refresh()
  }
  func handleKey(_ event: NSEvent) -> Bool {
    if textEditor != nil {
      if prefs.shortcut("TYPE_COMMIT_CURRENT_TOOL")?.matches(event) == true {
        commitText()
        return true
      }
      if event.keyCode == 53 {
        textEditor?.removeFromSuperview()
        textEditor = nil
        textDraft = nil
        editingTextID = nil
        window?.makeFirstResponder(self)
        refresh()
        return true
      }
      return false
    }
    if event.keyCode == 53 {
      if selectedID != nil || tool != nil {
        selectedID = nil
        tool = nil
        refresh()
      } else {
        onAction?(.exit)
      }
      return true
    }
    for action in Tool.allCases where prefs.shortcut(action.legacyName)?.matches(event) == true {
      if action.isDrawing || [.select, .moveSelection].contains(action) {
        setTool(action)
      } else {
        perform(action)
      }
      return true
    }
    for key in [
      "TYPE_TOGGLE_PANEL", "TYPE_SELECT_ALL", "TYPE_DELETE_CURRENT_TOOL", "TYPE_GRAB_COLOR",
    ] where prefs.shortcut(key)?.matches(event) == true {
      switch key {
      case "TYPE_TOGGLE_PANEL": onInspector?()
      case "TYPE_SELECT_ALL":
        setSelection(bounds)
        onRegionSettled?()
      case "TYPE_DELETE_CURRENT_TOOL": deleteSelected()
      default: onAction?(.select)
      }
      return true
    }
    for (key, delta) in [
      ("LEFT", CGSize(width: -1, height: 0)), ("RIGHT", CGSize(width: 1, height: 0)),
      ("UP", CGSize(width: 0, height: -1)), ("DOWN", CGSize(width: 0, height: 1)),
    ] {
      for mode in ["MOVE_", "RESIZE_", "SYM_RESIZE_"]
      where prefs.shortcut("TYPE_" + mode + key)?.matches(event) == true {
        guard var r = document.selection else { return true }
        if mode == "MOVE_" {
          r.origin.x += delta.width
          r.origin.y += delta.height
          r.origin.x = max(0, min(bounds.width - r.width, r.minX))
          r.origin.y = max(0, min(bounds.height - r.height, r.minY))
        } else {
          if mode == "SYM_RESIZE_" {
            r.origin.x -= delta.width
            r.origin.y -= delta.height
          }
          r.size.width = max(1, r.width + delta.width * (mode == "SYM_RESIZE_" ? 2 : 1))
          r.size.height = max(1, r.height + delta.height * (mode == "SYM_RESIZE_" ? 2 : 1))
        }
        setSelection(r)
        onRegionSettled?()
        return true
      }
    }
    return false
  }
  @objc func copy(_ sender: Any?) { onAction?(.copy) }
  override func selectAll(_ sender: Any?) {
    setSelection(bounds)
    onRegionSettled?()
  }
  override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }
  func perform(_ action: Tool) {
    switch action {
    case .undo:
      commitText()
      edits.undo()
      refresh()
    case .redo:
      commitText()
      edits.redo()
      refresh()
    case .clearSelection:
      commitText()
      setSelection(nil)
    case .sizeIncrease, .sizeDecrease:
      if let tool {
        Environment.shared.settings.set(
          tool.sizeKey,
          min(500, max(1, prefs.integer(tool.sizeKey) + (action == .sizeIncrease ? 1 : -1))))
        onChange?()
      }
    default: onAction?(action)
    }
  }
}
