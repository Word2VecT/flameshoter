# Native macOS design

The capture and annotation model remains Flameshot's C++/Qt implementation. The macOS view layer forwards native control actions to the existing tools and preserves their configured shortcuts. Other platform sources remain available without claiming Liquid Glass support there.

A native nonactivating NSPanel hosts the capture controls as a child of the capture window, keeping AppKit accessibility and focus separate from the Qt canvas. The floating capture bar uses NSGlassEffectView.contentView inside one NSGlassEffectContainerView. Drawing tools and final actions have separate groups, sharing a sampling container. Small screens use two rows rather than smaller hit targets. The macOS 27 interactive effect is enabled for control groups and availability-guarded; passive hints remain noninteractive.

The selected capture rectangle is an NSGlassEffectView with the Clear style. Outside it, NSVisualEffectView uses the semantic FullScreenUI material and WithinWindow blending to sample the frozen capture canvas, rather than the live desktop. Its public maskImage only describes the selection aperture. AppKit supplies the blur, tint, highlights, refraction, contrast and transparency behavior; no effect shader, Core Image blur or painted glass imitation is used. Selection geometry and input still belong to Flameshot. Material views return nil from hitTest so they do not consume selection or drawing input. Dimensions are native NSTextField content inside the glass so their glyphs are not refracted by the glass edge.

These views do not modify CaptureContext.screenshot or origScreenshot. Saving and copying use the original rectangular pixel crop and annotations, including the corner pixels obscured by the rounded preview material. The full-screen material strength reuses contrastOpacity; Reduce Transparency forces that material to full opacity. System appearance is inherited rather than replaced with a custom palette.

Preferences use NSTabViewController toolbars, NSScrollView and standard controls. All user settings exposed in the upstream macOS settings window are represented by native controls, with upload-only settings omitted when the uploader is not built. The native tool inspector includes colors and presets, sizes, text formatting and layer ordering. Existing INI option names remain compatible. Global shortcuts use the upstream QHotkey backend, and capture shortcuts retain Qt's macOS Command/Control mapping.

Icon layers are derived from the three upstream SVG paths. Apple Icon Composer 1.2 was used to import the layers and create the document; Apple's Xcode 27 asset compiler produces the shipping Assets.car and ICNS resources. Effects are material annotations, not baked highlights painted into the source flame layers. Light, dark and mono PNG previews were exported with Apple's ictool. The image-generation experiment is not a shipping asset.

System-provided materials, labels, controls and symbols are used to inherit light/dark, contrast, transparency and motion behavior. The release QA records which configurations were actually tested; use of native components does not substitute for accessibility testing or imply Apple certification.

## macOS UI audit

| Surface | Implementation |
| --- | --- |
| Launcher, preferences and tool inspector | NSWindow/NSPanel, NSTabViewController, NSScrollView, NSStackView and standard AppKit controls |
| Selection and outside material | NSGlassEffectView Clear and NSVisualEffectView FullScreenUI; no custom material renderer |
| Toolbar, help and error messages | Native glass, NSButton, NSTextField and SF Symbols; static hints do not enable interactive effects |
| Color controls and presets | NSColorWell/NSColorPanel and tinted SF Symbols, replacing the hand-painted preset circles |
| Save dialog | Qt's Cocoa native NSSavePanel bridge, with native dialogs explicitly enabled; the integration check observes save-panel |
| Permission, restart, discard and error dialogs | NSAlert; the legacy styled Qt discard dialog is not created on macOS |
| Open capture with another application | NSOpenPanel restricted to application bundles and NSWorkspace; the legacy Qt application list remains for other platforms |
| Pinned image shadow | NSWindow.hasShadow; the Qt colored drop-shadow effect is not attached on macOS |
| Menus and menu-bar item | Qt's Cocoa NSMenu/NSStatusItem bridge |

The screenshot canvas, annotation tools, text editing and pixel magnifier retain the Flameshot content model and rendering. Apple does not expose a public replacement for this complete editor or screenshot-region interaction. They are not represented as Apple-provided controls or Liquid Glass implementations. Legacy Qt settings/panels remain as configuration and tool adapters and for other platforms; macOS entry points route to the native interfaces listed above.

The material regression checks native view types, both appearances, selection masking, geometry changes, input passthrough and cleanup. A real fixture export was also compared pixel for pixel with its source crop, separately from preview screenshots. Actual macOS 26 runtime and a full accessibility interaction pass remain release-qualification work.

References:

- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/videos/play/wwdc2025/310/
- https://developer.apple.com/icon-composer/
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
