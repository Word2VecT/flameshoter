// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox

public struct Shortcut: Codable, Equatable, Sendable {
  public var keyCode: UInt16
  public var flags: UInt
  public init(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
    self.keyCode = keyCode
    self.flags = flags.rawValue
  }
  public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }
  public static let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
  public func matches(_ event: NSEvent) -> Bool {
    event.keyCode == keyCode
      && event.modifierFlags.intersection(Self.relevant) == modifiers.intersection(Self.relevant)
  }
  public var carbonFlags: UInt32 {
    var value: UInt32 = 0
    if modifiers.contains(.command) { value |= UInt32(cmdKey) }
    if modifiers.contains(.control) { value |= UInt32(controlKey) }
    if modifiers.contains(.option) { value |= UInt32(optionKey) }
    if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
    return value
  }
  public var display: String {
    var s = ""
    if modifiers.contains(.control) { s += "⌃" }
    if modifiers.contains(.option) { s += "⌥" }
    if modifiers.contains(.shift) { s += "⇧" }
    if modifiers.contains(.command) { s += "⌘" }
    return s + (Self.names[keyCode] ?? "Key \(keyCode)")
  }
  public static let names: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
    12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
    22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
    32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
    42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫",
    53: "Esc", 76: "⌤", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
    109: "F10", 111: "F12", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟",
    122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
  ]
  public init?(portable: String) {
    let parts = portable.split(separator: "+").map(String.init)
    guard var key = parts.last, !key.isEmpty else { return nil }
    var flags: NSEvent.ModifierFlags = []
    for part in parts.dropLast() {
      switch part.lowercased() {
      case "ctrl", "cmd", "command": flags.insert(.command)
      case "meta", "control": flags.insert(.control)
      case "alt", "option": flags.insert(.option)
      case "shift": flags.insert(.shift)
      default: return nil
      }
    }
    let aliases = [
      "return": "↩", "enter": "⌤", "space": "Space", "escape": "Esc", "esc": "Esc", "tab": "⇥",
      "backspace": "⌫", "delete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓",
      "minus": "−", "-": "−",
    ]
    key = aliases[key.lowercased()] ?? key.uppercased()
    guard let code = Self.names.first(where: { $0.value.lowercased() == key.lowercased() })?.key
    else { return nil }
    self.init(code, flags)
  }
  public var portable: String {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("Ctrl") }
    if modifiers.contains(.control) { parts.append("Meta") }
    if modifiers.contains(.option) { parts.append("Alt") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    let aliases: [String: String] = [
      "↩": "Return", "⌤": "Enter", "⇥": "Tab", "⌫": "Backspace", "⌦": "Delete", "←": "Left",
      "→": "Right", "↑": "Up", "↓": "Down", "−": "-", "Esc": "Escape",
    ]
    parts.append(aliases[Self.names[keyCode] ?? ""] ?? Self.names[keyCode] ?? "")
    return parts.joined(separator: "+")
  }
  public static var bindingNames: [String] {
    Set(defaults.keys).union(Tool.allCases.map(\.legacyName)).sorted()
  }
  public static var defaults: [String: Shortcut] {
    var d: [String: Shortcut] = [:]
    let definitions = [
      "TAKE_SCREENSHOT": "Ctrl+Shift+X", "TYPE_PENCIL": "P", "TYPE_DRAWER": "D", "TYPE_ARROW": "A",
      "TYPE_SELECTION": "S", "TYPE_RECTANGLE": "R", "TYPE_CIRCLE": "C", "TYPE_MARKER": "M",
      "TYPE_MOVESELECTION": "H", "TYPE_PIXELATE": "B", "TYPE_TEXT": "T", "TYPE_CIRCLECOUNT": "N",
      "TYPE_INVERT": "I", "TYPE_UNDO": "Ctrl+Z", "TYPE_REDO": "Ctrl+Shift+Z", "TYPE_COPY": "Ctrl+C",
      "TYPE_SAVE": "Ctrl+S", "TYPE_SHARE": "Ctrl+Shift+S", "TYPE_PIN": "Ctrl+P",
      "TYPE_OPEN_APP": "Ctrl+O", "TYPE_EXIT": "Escape",
      "TYPE_ACCEPT": "Return", "TYPE_CANCEL": "Ctrl+Backspace", "TYPE_TOGGLE_PANEL": "Space",
      "TYPE_SELECT_ALL": "Ctrl+A", "TYPE_COMMIT_CURRENT_TOOL": "Ctrl+Return",
      "TYPE_DELETE_CURRENT_TOOL": "Backspace", "TYPE_CLOSE_ACTIVE_PIN_WINDOW": "Ctrl+Q",
      "TYPE_GRAB_COLOR": "Ctrl+G", "TYPE_SIZEINCREASE": "=", "TYPE_SIZEDECREASE": "-",
      "TYPE_MOVE_LEFT": "Left", "TYPE_MOVE_RIGHT": "Right", "TYPE_MOVE_UP": "Up",
      "TYPE_MOVE_DOWN": "Down", "TYPE_RESIZE_LEFT": "Shift+Left",
      "TYPE_RESIZE_RIGHT": "Shift+Right", "TYPE_RESIZE_UP": "Shift+Up",
      "TYPE_RESIZE_DOWN": "Shift+Down", "TYPE_SYM_RESIZE_LEFT": "Alt+Left",
      "TYPE_SYM_RESIZE_RIGHT": "Alt+Right", "TYPE_SYM_RESIZE_UP": "Alt+Up",
      "TYPE_SYM_RESIZE_DOWN": "Alt+Down",
    ]
    for (k, v) in definitions { d[k] = Shortcut(portable: v) }
    return d
  }
}
