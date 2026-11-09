// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

enum AutoScroll {
  static func event(
    mouse: CGPoint, selection: CGRect, sourceIsActive: Bool,
    direction: LongCaptureDirection, primaryTop: CGFloat
  ) -> CGEvent? {
    guard sourceIsActive, selection.contains(mouse) else { return nil }
    let distance = Int32(
      max(20, min(120, (direction == .vertical ? selection.height : selection.width) / 4)))
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: direction == .vertical ? -distance : 0,
        wheel2: direction == .horizontal ? -distance : 0, wheel3: 0)
    else { return nil }
    event.location = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
    return event
  }
}
