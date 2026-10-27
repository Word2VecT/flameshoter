// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
import FlameshoterCore

@MainActor final class GlobalHotkey {
  private var hotkey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var current: Shortcut?
  var invoke: (() -> Void)?
  init() {
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { owner.invoke?() }
        return noErr
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
  func register(_ shortcut: Shortcut?) -> OSStatus {
    if shortcut == current { return noErr }
    if let hotkey {
      UnregisterEventHotKey(hotkey)
      self.hotkey = nil
    }
    current = nil
    guard let shortcut else { return noErr }
    let result = RegisterEventHotKey(
      UInt32(shortcut.keyCode), shortcut.carbonFlags, EventHotKeyID(signature: 0x466C_5368, id: 1),
      GetApplicationEventTarget(), 0, &hotkey)
    if result == noErr { current = shortcut }
    return result
  }
  deinit {
    if let hotkey { UnregisterEventHotKey(hotkey) }
    if let handler { RemoveEventHandler(handler) }
  }
}

@MainActor enum DockPolicy {
  static func update(_ application: NSApplication) {
    let normalWindow = application.windows.contains { window in
      !(window is CaptureWindow) && (window.isVisible || window.isMiniaturized)
        && window.styleMask.contains(.titled)
        && !window.styleMask.contains(.utilityWindow)
        && !window.styleMask.contains(.nonactivatingPanel)
    }
    let desired: NSApplication.ActivationPolicy = normalWindow ? .regular : .accessory
    if application.activationPolicy() != desired { application.setActivationPolicy(desired) }
  }
}
