// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices

struct SelectionWindow: Equatable, Sendable {
  let processID: pid_t
  let globalFrame: CGRect
  let localFrame: CGRect
}

enum AutoSelection {
  // Quartz and accessibility use a top-left origin on the primary display.
  static func displayFrame(_ screenFrame: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(
      x: screenFrame.minX, y: primaryTop - screenFrame.maxY,
      width: screenFrame.width, height: screenFrame.height)
  }

  static func localFrame(_ globalFrame: CGRect, display: CGRect) -> CGRect? {
    let clipped = globalFrame.intersection(display)
    guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
    return clipped.offsetBy(dx: -display.minX, dy: -display.minY)
  }

  static func windows(on display: CGRect) -> [SelectionWindow] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return windows(from: list, on: display, excluding: ProcessInfo.processInfo.processIdentifier)
  }

  static func windows(from list: [[String: Any]], on display: CGRect, excluding ownPID: pid_t)
    -> [SelectionWindow]
  {
    list.compactMap { item in
      guard let pid = item[kCGWindowOwnerPID as String] as? pid_t,
        pid != ownPID,
        (item[kCGWindowLayer as String] as? Int) == 0,
        (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let bounds = item[kCGWindowBounds as String] as? [String: Any],
        let global = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        let local = localFrame(global, display: display)
      else { return nil }
      return SelectionWindow(processID: pid, globalFrame: global, localFrame: local)
    }
  }

  static func window(at point: CGPoint, in windows: [SelectionWindow]) -> SelectionWindow? {
    windows.first { $0.localFrame.contains(point) }
  }

  static func accessibilityFrames(
    at point: CGPoint, window: SelectionWindow, display: CGRect
  ) -> [CGRect] {
    let app = AXUIElementCreateApplication(window.processID)
    AXUIElementSetMessagingTimeout(app, 0.15)
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &found) == .success,
      var element = found
    else { return [] }
    var frames: [CGRect] = []
    for _ in 0..<20 {
      if let global = frame(of: element), global.contains(point),
        let local = localFrame(global.intersection(window.globalFrame), display: display),
        !frames.contains(local)
      {
        frames.append(local)
      }
      var parent: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
        let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
      else { break }
      element = parent as! AXUIElement
    }
    return frames
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
      let rawPosition, let rawSize,
      CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
      AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }
}
