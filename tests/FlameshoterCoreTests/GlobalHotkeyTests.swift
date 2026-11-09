// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
import Testing

@testable import Flameshoter
@testable import FlameshoterCore

@Test @MainActor func globalHotkeyHandlersOnlyRunForTheirOwnIdentifier() throws {
  _ = NSApplication.shared
  let first = GlobalHotkey(identifier: 1401)
  let second = GlobalHotkey(identifier: 1402)
  var firstCount = 0
  var secondCount = 0
  first.invoke = { firstCount += 1 }
  second.invoke = { secondCount += 1 }
  var event: EventRef?
  #expect(
    CreateEvent(
      nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
      0, EventAttributes(kEventAttributeNone), &event) == noErr)
  let hotkeyEvent = try #require(event)
  defer { ReleaseEvent(hotkeyEvent) }
  var id = EventHotKeyID(signature: GlobalHotkey.signature, id: 1402)
  #expect(
    SetEventParameter(
      hotkeyEvent, EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
  #expect(SendEventToEventTarget(hotkeyEvent, GetApplicationEventTarget()) == noErr)
  #expect(firstCount == 0 && secondCount == 1)
  id.id = 1401
  #expect(
    SetEventParameter(
      hotkeyEvent, EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
  #expect(SendEventToEventTarget(hotkeyEvent, GetApplicationEventTarget()) == noErr)
  #expect(firstCount == 1 && secondCount == 1)
}

@Test func pinShortcutMigrationDoesNotOverrideAnExistingBinding() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("settings.json")
  var old = Preferences()
  old.schemaVersion = 5
  old.shortcuts.removeValue(forKey: "PIN_CLIPBOARD")
  old.shortcuts.removeValue(forKey: "RESTORE_PIN")
  old.shortcuts["TYPE_PENCIL"] = Shortcut(19, [.control, .shift])
  try JSONEncoder().encode(old).write(to: url)
  let upgraded = SettingsStore(url: url)
  #expect(upgraded.loadError == nil)
  #expect(upgraded.preferences.shortcut("PIN_CLIPBOARD") == nil)
  #expect(upgraded.preferences.shortcut("TYPE_PENCIL") == Shortcut(19, [.control, .shift]))
  #expect(upgraded.preferences.shortcut("RESTORE_PIN") == Shortcut(20, [.control, .shift]))
}
