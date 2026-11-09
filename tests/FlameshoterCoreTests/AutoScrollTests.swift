// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@Test func automaticScrollTargetsOnlyTheActiveSelection() throws {
  let selection = CGRect(x: 200, y: 100, width: 500, height: 300)
  let mouse = CGPoint(x: 300, y: 200)
  let vertical = try #require(
    AutoScroll.event(
      mouse: mouse, selection: selection, sourceIsActive: true, direction: .vertical,
      primaryTop: 900))
  #expect(vertical.location == CGPoint(x: 300, y: 700))
  #expect(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -75)
  #expect(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
  let horizontal = try #require(
    AutoScroll.event(
      mouse: mouse, selection: selection, sourceIsActive: true, direction: .horizontal,
      primaryTop: 900))
  #expect(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
  #expect(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -120)
  #expect(
    AutoScroll.event(
      mouse: mouse, selection: selection, sourceIsActive: false, direction: .vertical,
      primaryTop: 900) == nil)
  #expect(
    AutoScroll.event(
      mouse: .zero, selection: selection, sourceIsActive: true, direction: .vertical,
      primaryTop: 900) == nil)
}
