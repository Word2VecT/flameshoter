// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

// Empty space between the native glass buttons must still reach the capture canvas.
@MainActor final class ToolbarGlassContainer: NSGlassEffectContainerView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit is NSControl ? hit : nil
  }
}

/// Flameshot lays enabled tools clockwise around the selection, then inside it
/// when the screen edges leave no outside space. Coordinates are canvas-local.
enum CaptureToolbarLayout {
  static let buttonSize = CGSize(width: 50, height: 48)
  static func frames(count: Int, selection: CGRect, bounds: CGRect) -> [CGRect] {
    let area = bounds.insetBy(dx: 12, dy: 12)
    let pitch = CGSize(width: 56, height: 54)
    let gap: CGFloat = 10
    var frames: [CGRect] = []
    func append(_ origin: CGPoint) {
      let rect = CGRect(origin: origin, size: buttonSize)
      if frames.count < count, area.contains(rect),
        !frames.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) })
      {
        frames.append(rect)
      }
    }
    var ring = CGRect(
      x: selection.midX - max(buttonSize.width, selection.width) / 2,
      y: selection.midY - max(buttonSize.height, selection.height) / 2,
      width: max(buttonSize.width, selection.width),
      height: max(buttonSize.height, selection.height))
    for _ in 0..<count {
      let horizontal = max(1, Int(min(ring.width, area.width) / pitch.width))
      let vertical = max(1, Int(min(ring.height, area.height) / pitch.height))
      let x = min(
        area.maxX - CGFloat(horizontal) * pitch.width,
        max(area.minX, ring.midX - CGFloat(horizontal) * pitch.width / 2))
      let y = min(
        area.maxY - CGFloat(vertical) * pitch.height,
        max(area.minY, ring.midY - CGFloat(vertical) * pitch.height / 2))
      for i in 0..<horizontal {
        append(CGPoint(x: x + CGFloat(i) * pitch.width, y: ring.maxY + gap))
      }
      for i in 0..<vertical {
        append(CGPoint(x: ring.maxX + gap, y: y + CGFloat(i) * pitch.height))
      }
      for i in (0..<horizontal).reversed() {
        append(CGPoint(x: x + CGFloat(i) * pitch.width, y: ring.minY - gap - buttonSize.height))
      }
      for i in (0..<vertical).reversed() {
        append(CGPoint(x: ring.minX - gap - buttonSize.width, y: y + CGFloat(i) * pitch.height))
      }
      if frames.count == count || ring.contains(area) { break }
      ring = ring.insetBy(dx: -pitch.width, dy: -pitch.height)
    }
    // A full-screen selection has no outside edges available.
    if frames.count < count {
      let columns = max(1, Int((area.width + 6) / pitch.width))
      for row in 0..<max(1, Int((area.height + 6) / pitch.height)) {
        for column in 0..<columns {
          append(
            CGPoint(
              x: area.midX - (CGFloat(columns) * pitch.width - 6) / 2 + CGFloat(column)
                * pitch.width,
              y: area.maxY - buttonSize.height - CGFloat(row) * pitch.height))
        }
        if frames.count == count { break }
      }
    }
    return frames
  }
}

@MainActor final class CaptureToolbar: NSObject {
  weak var canvas: CanvasView?
  let root = ToolbarGlassContainer()
  private let content = FlippedView()
  private var items: [NSGlassEffectView] = []
  private var buttons: [Tool: ActionButton] = [:]
  private let inspectorButton: ActionButton
  private let popover = NSPopover()
  var isInspectorShown: Bool { popover.isShown }
  func dismissInspector() { popover.close() }
  private var inspector: ToolInspector?
  private var prefs: Preferences { Environment.shared.preferences }
  init(canvas: CanvasView, command: NativeCommand = NativeCommand()) {
    self.canvas = canvas
    inspectorButton = ActionButton("", symbol: "slider.horizontal.3", action: {})
    inspectorButton.toolTip = localized("Tool settings", "工具设置")
    inspectorButton.setAccessibilityLabel(localized("Tool settings", "工具设置"))
    super.init()
    root.spacing = 8
    root.contentView = content
    canvas.addSubview(root)
    root.setAccessibilityLabel(localized("Annotation toolbar", "标注工具栏"))
    inspectorButton.invoke = { [weak self] in self?.toggleInspector() }
    let outputRequested = command.copy || command.raw || command.path != nil || command.pin
    let excluded: [Tool] = outputRequested ? [.copy, .save, .openWith, .pin] : [.accept]
    for tool in Tool.toolbarOrder where prefs.tools.contains(tool) && !excluded.contains(tool) {
      items.append(glass(makeButton(tool), radius: 16))
    }
    if prefs.bool("showSidePanelButton") {
      configure(inspectorButton)
      items.append(glass(inspectorButton, radius: 16))
    }
    for item in items {
      item.translatesAutoresizingMaskIntoConstraints = true
      content.addSubview(item)
    }
    popover.behavior = .semitransient
    refresh()
  }
  private func configure(_ button: ActionButton) {
    button.bezelStyle = .accessoryBarAction
    button.isBordered = false
    button.widthAnchor.constraint(equalToConstant: 34).isActive = true
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
  }
  private func makeButton(_ tool: Tool) -> ActionButton {
    let button = ActionButton("", symbol: tool.symbol) { [weak self] in self?.invoke(tool) }
    configure(button)
    button.setAccessibilityLabel(toolTitle(tool))
    button.toolTip =
      toolTitle(tool) + (prefs.shortcut(tool.legacyName).map { "  \($0.display)" } ?? "")
    if tool.isDrawing || [.select, .moveSelection].contains(tool) {
      button.setButtonType(.pushOnPushOff)
    }
    buttons[tool] = button
    return button
  }
  private func invoke(_ tool: Tool) {
    if tool.isDrawing || [.select, .moveSelection].contains(tool) {
      canvas?.setTool(tool)
    } else {
      canvas?.perform(tool)
    }
    refresh()
  }
  func refresh() {
    guard let canvas else { return }
    for (tool, button) in buttons {
      button.state = canvas.tool == tool ? .on : .off
      button.contentTintColor = canvas.tool == tool ? .controlAccentColor : .labelColor
    }
    buttons[.undo]?.isEnabled = canvas.edits.canUndo
    buttons[.redo]?.isEnabled = canvas.edits.canRedo
    inspector?.refresh()
    guard let selection = canvas.document.selection else {
      root.isHidden = true
      popover.close()
      return
    }
    let frames = CaptureToolbarLayout.frames(
      count: items.count, selection: selection, bounds: canvas.bounds)
    let frame = frames.reduce(CGRect.null) { $0.union($1) }
    guard !frame.isNull else {
      root.isHidden = true
      return
    }
    root.frame = frame
    content.frame = CGRect(origin: .zero, size: frame.size)
    for (item, rect) in zip(items, frames) {
      item.frame = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
    root.layoutSubtreeIfNeeded()
    root.isHidden = false
  }
  func toggleInspector() {
    if popover.isShown {
      popover.close()
      return
    }
    guard let canvas else { return }
    let controller = ToolInspector(canvas: canvas)
    inspector = controller
    popover.contentViewController = controller
    popover.contentSize = NSSize(width: 360, height: min(640, canvas.bounds.height - 48))
    let anchor = inspectorButton.superview == nil ? root : inspectorButton
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    NSColorPanel.shared.level = NSWindow.Level(rawValue: (canvas.window?.level.rawValue ?? 0) + 1)
  }
  func hide() {
    popover.close()
    root.isHidden = true
  }
  func close() {
    popover.close()
    root.removeFromSuperview()
  }
}

@MainActor final class ToolInspector: NSViewController {
  weak var canvas: CanvasView?
  private let color: ActionColor
  private let size: ActionSlider
  private let sizeLabel = NSTextField(labelWithString: "")
  private let layers: ActionPopup
  private var layerIDs: [UUID] = []
  private let textOptions: NSStackView
  private let family: ActionPopup
  private var updating = false
  init(canvas: CanvasView) {
    self.canvas = canvas
    color = ActionColor(
      color: Environment.shared.preferences.color("drawColor").color, change: { _ in })
    size = ActionSlider(3, min: 1, max: 120, change: { _ in })
    layers = ActionPopup(
      items: [localized("No annotation selected", "未选择标注")], selected: 0, change: { _ in })
    let families =
      [localized("System font", "系统字体")] + NSFontManager.shared.availableFontFamilies.sorted()
    family = ActionPopup(items: families, selected: 0, change: { _ in })
    textOptions = stack([])
    super.init(nibName: nil, bundle: nil)
    color.change = { [weak self] color in
      guard let self, !self.updating else { return }
      Environment.shared.settings.set("drawColor", RGBA(color).hex)
      self.canvas?.applyStyle { $0.color = RGBA(color) }
      self.refresh()
    }
    size.change = { [weak self] value in
      guard let self, let canvas = self.canvas, !self.updating else { return }
      let tool = canvas.selectedAnnotation?.tool ?? canvas.tool ?? .pencil
      Environment.shared.settings.set(tool.sizeKey, Int(value.rounded()))
      canvas.applyStyle {
        if $0.tool == .text { $0.fontSize = value.rounded() } else { $0.width = value.rounded() }
      }
      self.refresh()
    }
    family.change = { [weak self] index in
      guard let self, !self.updating else { return }
      let value = index == 0 ? "" : families[index]
      Environment.shared.settings.set("fontFamily", value)
      self.canvas?.applyStyle { $0.font = value }
    }
    textOptions.addArrangedSubview(family)
    for (key, en, zh, change) in [
      ("textBold", "Bold", "粗体", { (a: inout Annotation, v: Bool) in a.bold = v }),
      ("textItalic", "Italic", "斜体", { (a: inout Annotation, v: Bool) in a.italic = v }),
      ("textUnderline", "Underline", "下划线", { (a: inout Annotation, v: Bool) in a.underline = v }),
      ("textStrike", "Strikethrough", "删除线", { (a: inout Annotation, v: Bool) in a.strike = v }),
    ] {
      textOptions.addArrangedSubview(
        ActionCheck(localized(en, zh), on: Environment.shared.preferences.bool(key)) {
          [weak self] value in
          Environment.shared.settings.set(key, value)
          self?.canvas?.applyStyle { change(&$0, value) }
        })
    }
    let alignment = ActionPopup(
      items: [localized("Left", "左对齐"), localized("Center", "居中"), localized("Right", "右对齐")],
      selected: Environment.shared.preferences.integer("textAlignment")
    ) { [weak self] value in
      Environment.shared.settings.set("textAlignment", value)
      self?.canvas?.applyStyle { $0.alignment = value }
    }
    textOptions.addArrangedSubview(alignment)
    layers.change = { [weak self] index in
      guard let self, !self.updating else { return }
      self.canvas?.selectedID =
        index > 0 && index <= self.layerIDs.count ? self.layerIDs[index - 1] : nil
      self.canvas?.tool = .select
      self.canvas?.refresh()
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func loadView() {
    let column = stack([label(localized("Tool settings", "工具设置"), size: 17)])
    var colors = Environment.shared.preferences.colors
    if Environment.shared.preferences.bool("predefinedColorPaletteLarge"),
      let palette = NSColorList.availableColorLists.first(where: { $0.name == "Crayons" })
        ?? NSColorList.availableColorLists.first
    {
      colors += palette.allKeys.prefix(24).compactMap { palette.color(withKey: $0).map(RGBA.init) }
    }
    var row: [NSView] = []
    for (index, value) in colors.enumerated() {
      let button = ActionButton("", symbol: "circle.fill") { [weak self] in
        Environment.shared.settings.set("drawColor", value.hex)
        self?.canvas?.applyStyle { $0.color = value }
        self?.refresh()
      }
      button.contentTintColor = value.color
      button.toolTip = value.hex
      button.setAccessibilityLabel(value.hex)
      button.widthAnchor.constraint(equalToConstant: 36).isActive = true
      row.append(button)
      if row.count == 6 || index == colors.count - 1 {
        column.addArrangedSubview(stack(row, vertical: false, spacing: 5))
        row = []
      }
    }
    column.addArrangedSubview(
      stack([label(localized("Annotation color", "标注颜色")), color], vertical: false))
    column.addArrangedSubview(stack([label(localized("Size", "尺寸")), sizeLabel], vertical: false))
    column.addArrangedSubview(size)
    column.addArrangedSubview(textOptions)
    column.addArrangedSubview(
      ActionCheck(
        localized("Fill shapes", "填充图形"), on: Environment.shared.preferences.bool("filledShapes")
      ) { [weak self] value in
        Environment.shared.settings.set("filledShapes", value)
        self?.canvas?.applyStyle { $0.filled = value }
      })
    column.addArrangedSubview(label(localized("Annotation layers", "标注图层"), size: 14))
    column.addArrangedSubview(layers)
    column.addArrangedSubview(
      stack(
        [
          ActionButton(localized("Back", "下移"), symbol: "arrow.down") { [weak self] in
            self?.canvas?.moveLayer(-1)
          },
          ActionButton(localized("Front", "上移"), symbol: "arrow.up") { [weak self] in
            self?.canvas?.moveLayer(1)
          },
          ActionButton(localized("Delete", "删除"), symbol: "trash") { [weak self] in
            self?.canvas?.deleteSelected()
          },
        ], vertical: false))
    column.addArrangedSubview(
      label(
        localized(
          "Right-click or press Space to open these controls. Redaction uses surrounding colors by default; traditional pixelation can retain information.",
          "右键或按空格打开此面板。遮挡默认使用周围颜色；传统像素化可能保留原始信息。"), secondary: true))
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let content = FlippedView()
    scroll.documentView = content
    content.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      column.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    content.translatesAutoresizingMaskIntoConstraints = false
    view = scroll
    refresh()
  }
  func refresh() {
    guard let canvas else { return }
    updating = true
    defer { updating = false }
    let selected = canvas.selectedAnnotation
    let prefs = Environment.shared.preferences
    color.color = (selected?.color ?? prefs.color("drawColor")).color
    let tool = selected?.tool ?? canvas.tool ?? .pencil
    let value =
      tool == .text
      ? selected?.fontSize ?? Double(prefs.integer("drawFontSize"))
      : selected?.width ?? Double(prefs.integer(tool.sizeKey))
    size.maxValue = max(120, value)
    size.doubleValue = value
    sizeLabel.stringValue = String(Int(value))
    textOptions.isHidden = tool != .text
    layerIDs = canvas.document.annotations.map(\.id)
    layers.removeAllItems()
    layers.addItem(withTitle: localized("No annotation selected", "未选择标注"))
    for (index, a) in canvas.document.annotations.enumerated() {
      layers.addItem(
        withTitle:
          "\(index+1). \(toolTitle(a.tool))\(a.text.isEmpty ? "" : " · "+String(a.text.prefix(24)))"
      )
    }
    if let id = canvas.selectedID, let index = layerIDs.firstIndex(of: id) {
      layers.selectItem(at: index + 1)
    } else {
      layers.selectItem(at: 0)
    }
  }
}
