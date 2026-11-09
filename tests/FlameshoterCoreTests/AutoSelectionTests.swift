// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@Test func automaticWindowSelectionMapsDisplaysAndPreservesStackingOrder() throws {
  let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let left = CGRect(x: -1200, y: 200, width: 1200, height: 800)
  let display = AutoSelection.displayFrame(left, primaryTop: primary.maxY)
  #expect(display == CGRect(x: -1200, y: -100, width: 1200, height: 800))
  #expect(AutoSelection.localFrame(
    CGRect(x: -1300, y: -50, width: 300, height: 200), display: display)
    == CGRect(x: 0, y: 50, width: 200, height: 200))
  #expect(AutoSelection.localFrame(CGRect(x: 0, y: 0, width: 50, height: 50), display: display) == nil)
  let front = SelectionWindow(
    processID: 1, globalFrame: CGRect(x: -1100, y: 0, width: 200, height: 200),
    localFrame: CGRect(x: 100, y: 100, width: 200, height: 200))
  let back = SelectionWindow(
    processID: 2, globalFrame: CGRect(x: -1200, y: -100, width: 600, height: 500),
    localFrame: CGRect(x: 0, y: 0, width: 600, height: 500))
  #expect(AutoSelection.window(at: CGPoint(x: 150, y: 150), in: [front, back]) == front)
  #expect(AutoSelection.window(at: CGPoint(x: 350, y: 150), in: [front, back]) == back)
  #expect(AutoSelection.window(at: CGPoint(x: 700, y: 150), in: [front, back]) == nil)
}

@Test func automaticSelectionReadsNativeWindowDictionaries() {
  let display = CGRect(x: 0, y: 0, width: 800, height: 600)
  func item(_ pid: Int32, _ layer: Int, _ alpha: Double, _ rect: CGRect) -> [String: Any] {
    [
      kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
      kCGWindowAlpha as String: NSNumber(value: alpha),
      kCGWindowBounds as String: ["X": rect.minX, "Y": rect.minY, "Width": rect.width, "Height": rect.height],
    ]
  }
  let list = [
    item(11, 0, 1, CGRect(x: 20, y: 30, width: 200, height: 100)),
    item(22, 0, 1, CGRect(x: 0, y: 0, width: 400, height: 400)),
    item(33, 3, 1, display), item(44, 0, 0, display), item(55, 0, 1, display),
  ]
  let windows = AutoSelection.windows(from: list, on: display, excluding: 55)
  #expect(windows.map(\.processID) == [11, 22])
  #expect(windows.first?.localFrame == CGRect(x: 20, y: 30, width: 200, height: 100))
}

@Test @MainActor func automaticSelectionSupportsClickAndFreeDrag() throws {
  _ = NSApplication.shared
  let store = Environment.shared.settings
  let previous = store.preferences
  defer { store.update { $0 = previous } }
  store.set("autoSelectionMode", 1)
  let screen = try #require(NSScreen.main)
  let image = try #require(CGContext(
    data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )?.makeImage())
  var frame = CapturedScreen(image: image, screen: screen)
  let region = CGRect(x: 100, y: 100, width: 300, height: 200)
  frame.windows = [SelectionWindow(processID: 1, globalFrame: region, localFrame: region)]
  let canvas = CanvasView(frame: frame)
  let window = CaptureWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = canvas
  defer { window.close() }
  var settled = 0
  canvas.onRegionSettled = { settled += 1 }
  func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  let start = CGPoint(x: 150, y: 150)
  canvas.mouseMoved(with: event(.mouseMoved, start))
  #expect(canvas.suggestedSelection == region)
  #expect(canvas.document.selection == nil)
  canvas.mouseDown(with: event(.leftMouseDown, start))
  canvas.mouseUp(with: event(.leftMouseUp, start))
  #expect(canvas.document.selection == region)
  #expect(settled == 1)
  canvas.setSelection(nil)
  canvas.mouseMoved(with: event(.mouseMoved, start))
  let end = CGPoint(x: 250, y: 220)
  canvas.mouseDown(with: event(.leftMouseDown, start))
  canvas.mouseDragged(with: event(.leftMouseDragged, end))
  canvas.mouseUp(with: event(.leftMouseUp, end))
  #expect(canvas.document.selection == CGRect(x: 150, y: 150, width: 100, height: 70))
  #expect(settled == 2)
  canvas.setSelection(nil)
  // A click without an intervening mouse-move still selects the window under the pointer.
  canvas.mouseDown(with: event(.leftMouseDown, start))
  canvas.mouseUp(with: event(.leftMouseUp, start))
  #expect(canvas.document.selection == region)
  #expect(settled == 3)
}

@Test @MainActor func captureSourceComesFromTheOriginalWindowSnapshot() throws {
  _ = NSApplication.shared
  let screen = try #require(NSScreen.main)
  let image = try #require(CGContext(
    data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )?.makeImage())
  var frame = CapturedScreen(image: image, screen: screen)
  let region = CGRect(x: 100, y: 100, width: 300, height: 200)
  frame.windows = [SelectionWindow(
    processID: ProcessInfo.processInfo.processIdentifier, globalFrame: region, localFrame: region)]
  let canvas = CanvasView(frame: frame)
  #expect(canvas.sourceApplication(at: CGPoint(x: 150, y: 150))?.processIdentifier
    == ProcessInfo.processInfo.processIdentifier)
  #expect(canvas.sourceApplication(at: .zero) == nil)
}
