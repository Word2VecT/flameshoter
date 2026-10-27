# Native macOS design

The capture and annotation model remains Flameshot's C++/Qt implementation. The macOS view layer forwards native control actions to the existing tools and preserves their configured shortcuts. Other platform sources remain available without claiming Liquid Glass support there.

A native nonactivating NSPanel hosts the capture controls as a child of the capture window, keeping AppKit accessibility and focus separate from the Qt canvas. The floating capture bar uses NSGlassEffectView.contentView inside one NSGlassEffectContainerView. Drawing tools and final actions have separate groups, sharing a sampling container. The screenshot is the content layer; glass is restricted to the floating functional layer. Small screens use two rows rather than smaller hit targets. The macOS 27 interactive effect is availability-guarded; macOS 26 uses its system material implementation. No private UI APIs, CSS blur approximation, or custom reflection shader is used.

Preferences use NSTabViewController toolbars, NSScrollView and standard controls. All user settings exposed in the upstream macOS settings window are represented by native controls, with upload-only settings omitted when the uploader is not built. The native tool inspector includes colors and presets, sizes, text formatting and layer ordering. Existing INI option names remain compatible. Global shortcuts use the upstream QHotkey backend, and capture shortcuts retain Qt's macOS Command/Control mapping.

Icon layers are derived from the three upstream SVG paths. Apple Icon Composer 1.2 was used to import the layers and create the document; Apple's Xcode 27 asset compiler produces the shipping Assets.car and ICNS resources. Effects are material annotations, not baked highlights painted into the source flame layers. Light, dark and mono PNG previews were exported with Apple's ictool. The image-generation experiment is not a shipping asset.

System-provided materials, labels, controls and symbols are used to inherit light/dark, contrast, transparency and motion behavior. The release QA records which configurations were actually tested; use of native components does not substitute for accessibility testing or imply Apple certification.

References:

- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/videos/play/wwdc2025/310/
- https://developer.apple.com/icon-composer/
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
