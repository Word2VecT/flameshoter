// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2017-2019 Alejandro Sirgo Rica & Contributors
import CoreGraphics

/// Port of Flameshot ButtonHandler's placement algorithm, including QRect's
/// inclusive integer edges. Keep geometry independent of AppKit controls.
/// Upstream: da34dcb1b296bd2e3bc589767abbe788084215ae,
/// src/widgets/capture/buttonhandler.cpp.
struct CaptureToolbarLayout {
  private struct Rect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var right: Int { x + width - 1 }
    var bottom: Int { y + height - 1 }
    var center: Point { Point(x: (x + right) / 2, y: (y + bottom) / 2) }
    init(_ r: CGRect) {
      x = Int(r.minX.rounded())
      y = Int(r.minY.rounded())
      width = Int(r.width.rounded())
      height = Int(r.height.rounded())
    }
    func contains(_ point: Point) -> Bool {
      point.x >= x && point.x <= right && point.y >= y && point.y <= bottom
    }
    mutating func intersect(_ other: Rect) {
      let maxX = min(right, other.right)
      let maxY = min(bottom, other.bottom)
      x = max(x, other.x)
      y = max(y, other.y)
      width = max(0, maxX - x + 1)
      height = max(0, maxY - y + 1)
    }
  }
  private struct Point {
    var x: Int
    var y: Int
  }
  private let count: Int
  private let base: Int
  private let separator: Int
  private let extended: Int
  private let screen: Rect
  private var selection: Rect
  private var positions: [CGRect] = []
  private var blockedRight = false
  private var blockedLeft = false
  private var blockedBottom = false
  private var blockedTop = false
  private var oneHorizontalBlocked: Bool { blockedRight != blockedLeft }
  private var horizontallyBlocked: Bool { blockedRight && blockedLeft }
  private var allSidesBlocked: Bool { blockedBottom && horizontallyBlocked && blockedTop }
  private init(count: Int, selection: CGRect, bounds: CGRect, baseSize: Int) {
    self.count = count
    base = baseSize
    separator = baseSize / 4
    extended = baseSize + baseSize / 4
    screen = Rect(bounds)
    self.selection = Rect(selection)
  }
  static func frames(count: Int, selection: CGRect, bounds: CGRect, baseSize: Int = 40) -> [CGRect]
  {
    var layout = Self(count: count, selection: selection, bounds: bounds, baseSize: baseSize)
    return layout.updatePosition()
  }
  private mutating func updatePosition() -> [CGRect] {
    let original = selection
    selection.intersect(screen)
    updateBlockedSides()
    ensureSelectionMinimumSize()
    while positions.count < count {
      if allSidesBlocked {
        selection = original
        positionButtonsInside()
        break
      }
      let perRow = (selection.width + separator) / extended
      let perColumn = (selection.height + separator) / extended
      var corners = min(4, count - positions.count - (perRow + perColumn) * 2)
      let maxExtra = oneHorizontalBlocked ? 1 : (horizontallyBlocked ? 0 : 2)
      let topCorners = min(max(0, corners), maxExtra)
      corners -= topCorners
      let bottomCorners = min(max(0, corners), maxExtra)
      if !blockedBottom {
        let n = min(perRow + bottomCorners, count - positions.count)
        var center = Point(x: selection.center.x, y: selection.bottom + separator)
        if n > perRow { adjustHorizontalCenter(&center) }
        horizontalPoints(center, count: n, leftToRight: true)
      }
      if !blockedRight && positions.count < count {
        verticalPoints(
          Point(x: selection.right + separator, y: selection.center.y),
          count: min(perColumn, count - positions.count), upToDown: false)
      }
      if !blockedTop && positions.count < count {
        let n = min(perRow + topCorners, count - positions.count)
        var center = Point(x: selection.center.x, y: selection.y - extended)
        if n == 1 + perRow { adjustHorizontalCenter(&center) }
        horizontalPoints(center, count: n, leftToRight: false)
      }
      if !blockedLeft && positions.count < count {
        verticalPoints(
          Point(x: selection.x - extended, y: selection.center.y),
          count: min(perColumn, count - positions.count), upToDown: true)
      }
      if positions.count < count && !allSidesBlocked {
        selection.x -= extended
        selection.y -= extended
        selection.width += extended * 2
        selection.height += extended * 2
        selection.intersect(screen)
      }
      updateBlockedSides()
    }
    return positions
  }
  private func calculateShift(_ elements: Int, reverse: Bool) -> Int {
    let shift =
      elements.isMultiple(of: 2)
      ? extended * (elements / 2) - separator / 2
      : extended * ((elements - 1) / 2) + base / 2
    return reverse ? shift : shift - base
  }
  private mutating func horizontalPoints(_ center: Point, count: Int, leftToRight: Bool) {
    let shift = calculateShift(count, reverse: leftToRight)
    let x = leftToRight ? center.x - shift : center.x + shift
    for i in 0..<count {
      append(Point(x: x + (leftToRight ? i : -i) * extended, y: center.y))
    }
  }
  private mutating func verticalPoints(_ center: Point, count: Int, upToDown: Bool) {
    let shift = calculateShift(count, reverse: upToDown)
    let y = upToDown ? center.y - shift : center.y + shift
    for i in 0..<count {
      append(Point(x: center.x, y: y + (upToDown ? i : -i) * extended))
    }
  }
  private mutating func append(_ point: Point) {
    positions.append(CGRect(x: point.x, y: point.y, width: base, height: base))
  }
  private mutating func updateBlockedSides() {
    let extensionSize = separator * 2 + base
    blockedRight =
      !(screen.contains(Point(x: selection.right + extensionSize, y: selection.bottom))
      && screen.contains(Point(x: selection.right + extensionSize, y: selection.y)))
    blockedLeft =
      !(screen.contains(Point(x: selection.x - extensionSize, y: selection.bottom))
      && screen.contains(Point(x: selection.x - extensionSize, y: selection.y)))
    blockedBottom =
      !(screen.contains(Point(x: selection.x, y: selection.bottom + extensionSize))
      && screen.contains(Point(x: selection.right, y: selection.bottom + extensionSize)))
    blockedTop =
      !(screen.contains(Point(x: selection.x, y: selection.y - extensionSize))
      && screen.contains(Point(x: selection.right, y: selection.y - extensionSize)))
  }
  private mutating func ensureSelectionMinimumSize() {
    if selection.width < base {
      if !blockedLeft { selection.x -= (base - selection.width) / 2 }
      selection.width = base
    }
    if selection.height < base {
      if !blockedTop { selection.y -= (base - selection.height) / 2 }
      selection.height = base
    }
  }
  private mutating func positionButtonsInside() {
    selection.intersect(screen)
    let perRow = selection.width / extended
    guard perRow > 0 else { return }
    var center = Point(x: selection.center.x, y: selection.bottom - extended)
    while positions.count < count {
      horizontalPoints(center, count: min(perRow, count - positions.count), leftToRight: true)
      center.y -= extended
    }
  }
  private func adjustHorizontalCenter(_ center: inout Point) {
    if blockedLeft { center.x += extended / 2 } else if blockedRight { center.x -= extended / 2 }
  }
}
