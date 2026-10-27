# Flameshoter 0.2.0

Flameshoter is now a native macOS app built with Swift / AppKit. Qt, CMake and all third-party runtime libraries have been removed.

- ScreenCaptureKit region, display and all-display capture, with command-line support.
- Swift / Core Graphics annotations, native text editing, layers, copy, save, external-app opening and pinned captures.
- Apple Clear Liquid Glass selection, FullScreenUI outside frost and native glass tool groups. Exported pixels exclude preview materials.
- Seven native settings pages, Chinese and English UI, shortcut recording and migration from existing INI preferences.
- Dock hides when the last ordinary window closes while the menu-bar icon remains. Minimized windows retain their Dock presence.
- Apple Icon Composer assets, Homebrew cask and the existing fixed signing identity are retained.

Requires Apple Silicon and macOS 26+. Export formats follow Apple ImageIO encoder support. No Linux or Windows build is provided. Self-signed releases are not Apple notarized and may require Open Anyway on first installation.
