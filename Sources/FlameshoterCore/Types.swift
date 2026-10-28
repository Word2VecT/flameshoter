// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

public struct RGBA: Codable, Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double
  public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
  public init(_ color: NSColor) {
    let c = color.usingColorSpace(.sRGB) ?? .systemRed
    self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
  }
  public init?(hex: String) {
    let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: "#", with: "")
    guard s.count == 6 || s.count == 8, let n = UInt64(s, radix: 16) else { return nil }
    // Qt stores 8-digit colors as AARRGGBB.
    self.init(
      Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255,
      Double(n & 255) / 255, s.count == 8 ? Double((n >> 24) & 255) / 255 : 1)
  }
  public var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
  public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
  public var hex: String {
    String(
      format: "#%02x%02x%02x%02x", Int(alpha * 255), Int(red * 255), Int(green * 255),
      Int(blue * 255))
  }
  public static let red = RGBA(1, 0.23, 0.19)
  public static let defaults = [
    RGBA.red, RGBA(1, 0.58, 0), RGBA(1, 0.8, 0), RGBA(0.2, 0.78, 0.35), RGBA(0, 0.48, 1),
    RGBA(0.69, 0.32, 0.87), RGBA(0, 0, 0), RGBA(1, 1, 1),
  ]
}

public enum Tool: Int, Codable, CaseIterable, Identifiable, Sendable {
  case pencil = 0
  case line = 1
  case arrow = 2
  case select = 3
  case rectangle = 4
  case ellipse = 5
  case marker = 6
  case moveSelection = 8
  case undo = 9
  case copy = 10
  case save = 11
  case exit = 12
  case openWith = 14
  case pixelate = 15
  case redo = 16
  case pin = 17
  case text = 18
  case counter = 19
  case sizeIncrease = 20
  case sizeDecrease = 21
  case invert = 22
  case accept = 23
  case clearSelection = 24
  case share = 25
  // Preserve Flameshot's getIterableButtonTypes() order, adding native Share after Save.
  public static let toolbarOrder: [Tool] = [
    .pencil, .line, .arrow, .select, .rectangle, .ellipse, .marker, .text,
    .counter, .pixelate, .invert, .moveSelection, .undo, .redo, .copy, .save, .share,
    .exit, .pin, .sizeIncrease, .sizeDecrease, .accept,
  ]
  public static let defaultToolbar = toolbarOrder.filter {
    ![Tool.sizeIncrease, .sizeDecrease].contains($0)
  }
  public var id: Int { rawValue }
  public var isDrawing: Bool {
    [.pencil, .line, .arrow, .rectangle, .ellipse, .marker, .pixelate, .text, .counter, .invert]
      .contains(self)
  }
  public var title: (String, String) {
    switch self {
    case .pencil: return ("Pencil", "画笔")
    case .line: return ("Line", "直线")
    case .arrow: return ("Arrow", "箭头")
    case .select: return ("Select annotation", "选择标注")
    case .rectangle: return ("Rectangle", "矩形")
    case .ellipse: return ("Ellipse", "椭圆")
    case .marker: return ("Highlighter", "荧光笔")
    case .moveSelection: return ("Move capture region", "移动截图区域")
    case .undo: return ("Undo", "撤销")
    case .copy: return ("Copy", "复制")
    case .save: return ("Save", "保存")
    case .share: return ("Share", "分享")
    case .exit: return ("Cancel capture", "取消截图")
    case .openWith: return ("Open with…", "使用其他应用打开…")
    case .pixelate: return ("Redact / pixelate", "遮挡 / 马赛克")
    case .redo: return ("Redo", "重做")
    case .pin: return ("Pin capture", "置顶截图")
    case .text: return ("Text", "文字")
    case .counter: return ("Number", "序号")
    case .sizeIncrease: return ("Increase size", "增大尺寸")
    case .sizeDecrease: return ("Decrease size", "减小尺寸")
    case .invert: return ("Invert colors", "反转颜色")
    case .accept: return ("Accept capture", "完成截图")
    case .clearSelection: return ("Clear capture region", "清除截图选区")
    }
  }
  public var symbol: String {
    switch self {
    case .pencil: return "pencil.tip"
    case .line: return "line.diagonal"
    case .arrow: return "arrow.up.right"
    case .select: return "cursorarrow"
    case .rectangle: return "rectangle"
    case .ellipse: return "circle"
    case .marker: return "highlighter"
    case .moveSelection: return "arrow.up.and.down.and.arrow.left.and.right"
    case .undo: return "arrow.uturn.backward"
    case .redo: return "arrow.uturn.forward"
    case .copy: return "document.on.document"
    case .save: return "square.and.arrow.down"
    case .exit: return "xmark"
    case .openWith: return "square.and.arrow.up"
    case .share: return "square.and.arrow.up"
    case .pixelate: return "square.dashed.inset.filled"
    case .pin: return "pin"
    case .text: return "textformat"
    case .counter: return "number.circle"
    case .sizeIncrease: return "plus"
    case .sizeDecrease: return "minus"
    case .invert: return "circle.lefthalf.filled"
    case .accept: return "checkmark"
    case .clearSelection: return "selection.pin.in.out"
    }
  }
  public var legacyName: String {
    let names: [Tool: String] = [
      .pencil: "PENCIL", .line: "DRAWER", .arrow: "ARROW", .select: "SELECTION",
      .rectangle: "RECTANGLE", .ellipse: "CIRCLE", .marker: "MARKER",
      .moveSelection: "MOVESELECTION", .undo: "UNDO", .copy: "COPY", .save: "SAVE", .exit: "EXIT",
      .openWith: "OPEN_APP", .pixelate: "PIXELATE", .redo: "REDO", .pin: "PIN", .text: "TEXT",
      .counter: "CIRCLECOUNT", .sizeIncrease: "SIZEINCREASE", .sizeDecrease: "SIZEDECREASE",
      .invert: "INVERT", .accept: "ACCEPT", .clearSelection: "CANCEL", .share: "SHARE",
    ]
    return "TYPE_" + names[self]!
  }
  public var sizeKey: String {
    switch self {
    case .rectangle: return "drawRectangleSize"
    case .marker: return "drawMarkerSize"
    case .pixelate: return "drawPixelateSize"
    case .text: return "drawFontSize"
    case .counter: return "drawCircleCounterSize"
    default: return "drawThickness"
    }
  }
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var tool: Tool
  public var points: [CGPoint]
  public var color: RGBA
  public var width: Double
  public var text = ""
  public var font = ""
  public var fontSize = 24.0
  public var bold = false
  public var italic = false
  public var underline = false
  public var strike = false
  public var alignment = 0
  public var filled = false
  public var number = 1
  public var reverseArrow = false
  public var curvedArrow = false
  public var outlinedCounter = true
  public var traditionalPixelation = false
  public init(tool: Tool, points: [CGPoint], color: RGBA = .red, width: Double = 3) {
    self.tool = tool
    self.points = points
    self.color = color
    self.width = width
  }
  public var bounds: CGRect {
    guard let first = points.first else { return .zero }
    if tool == .text {
      return CGRect(
        origin: first,
        size: CGSize(
          width: max(120, points.last.map { abs($0.x - first.x) } ?? 0),
          height: max(
            fontSize * 1.8, Double(text.components(separatedBy: "\n").count) * fontSize * 1.4)))
    }
    if tool == .counter {
      return CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)
    }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    return CGRect(
      x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }
  public mutating func move(by delta: CGSize) {
    points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
  }
  public func hitTest(_ point: CGPoint, tolerance: CGFloat = 7) -> Bool {
    guard bounds.insetBy(dx: -max(tolerance, width), dy: -max(tolerance, width)).contains(point)
    else { return false }
    if [.pencil, .marker, .line, .arrow].contains(tool), points.count > 1 {
      return zip(points, points.dropFirst()).contains { a, b in
        let dx = b.x - a.x
        let dy = b.y - a.y
        let square = dx * dx + dy * dy
        let t =
          square > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / square)) : 0
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
          <= max(tolerance, width / 2)
      }
    }
    return true
  }
}

public struct CaptureDocument {
  public let image: CGImage
  public let logicalSize: CGSize
  public var selection: CGRect?
  public private(set) var annotations: [Annotation] = []
  private var past: [[Annotation]] = []
  private var future: [[Annotation]] = []
  public var undoLimit: Int
  public var scale: CGFloat { CGFloat(image.width) / logicalSize.width }
  public var canUndo: Bool { !past.isEmpty }
  public var canRedo: Bool { !future.isEmpty }
  public init(image: CGImage, logicalSize: CGSize, undoLimit: Int = 100) {
    self.image = image
    self.logicalSize = logicalSize
    self.undoLimit = undoLimit
  }
  public mutating func replaceAnnotations(_ updated: [Annotation], recordingUndo: Bool = true) {
    guard updated != annotations else { return }
    if recordingUndo {
      past.append(annotations)
      if undoLimit > 0 && past.count > undoLimit { past.removeFirst(past.count - undoLimit) }
      future.removeAll()
    }
    annotations = updated
  }
  public mutating func add(_ annotation: Annotation) {
    replaceAnnotations(annotations + [annotation])
  }
  public mutating func remove(_ id: UUID) { replaceAnnotations(annotations.filter { $0.id != id }) }
  public mutating func undo() {
    guard let previous = past.popLast() else { return }
    future.append(annotations)
    annotations = previous
  }
  public mutating func redo() {
    guard let next = future.popLast() else { return }
    past.append(annotations)
    annotations = next
  }
  public func annotation(at point: CGPoint) -> Annotation? {
    annotations.reversed().first { $0.hitTest(point) }
  }
  public var pixelSelection: CGRect {
    let r = (selection ?? CGRect(origin: .zero, size: logicalSize)).intersection(
      CGRect(origin: .zero, size: logicalSize))
    return CGRect(
      x: (r.minX * scale).rounded(), y: (r.minY * scale).rounded(),
      width: (r.width * scale).rounded(), height: (r.height * scale).rounded()
    ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
}
