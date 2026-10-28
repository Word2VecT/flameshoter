# Native macOS design

Flameshoter is a native Swift package. FlameshoterCore owns preferences, legacy INI migration, shortcuts, image coordinates, annotations and export. Flameshoter owns the AppKit lifecycle, ScreenCaptureKit capture, canvas input, native controls and command bridge. Vendored libwebp C sources supply lossless WebP encoding; an embedded OxiPNG executable supplies PNG optimization.

## Materials and controls

| Surface | Public Apple implementation |
| --- | --- |
| Capture selection | NSGlassEffectView Clear covering the selected rectangle |
| Outside selection | NSVisualEffectView FullScreenUI, WithinWindow blending, maskImage aperture |
| Floating toolbar / static instructions | NSGlassEffectContainerView and NSGlassEffectView Regular |
| Settings / inspector | NSTabViewController, NSScrollView, NSPopover, NSStackView and standard controls |
| Colors / text / undo | NSColorWell, NSColorPanel, NSColorSampler, NSTextView and UndoManager |
| Save / external app | NSSavePanel, NSOpenPanel and NSWorkspace |
| Permissions / confirmation / errors | NSAlert |
| Pinned image | NSWindow with system shadow and NSImageView |
| Menu bar / menus | NSStatusItem and NSMenu |
| Global shortcut | Carbon RegisterEventHotKey; no Accessibility permission required |

The selected screenshot is foreground NSImageView content inside Clear glass. Its inset exposes a system-rendered material rim while leaving content legible. Passive material views return nil from hitTest. The outside material samples the frozen canvas, not a changing live desktop. AppKit renders refraction, blur, highlights and appearance; there is no custom glass shader or blur filter.

Selection masks and corner clipping describe geometry only. Dimensions are NSTextField content above the material. System colors and SF Symbols follow appearance. Reduce Transparency forces outside frost to full opacity; custom tint is an explicit preference. The macOS 27 interactive effect is availability-guarded, while macOS 26 uses the default native behavior.

## Capture and annotations

SCScreenshotManager captures each display in SDR at its backing scale and excludes this app. Full-display CLI capture combines frames in desktop layout at the highest display scale; spaces between displays remain black. Each interactive display has a native capture window with native glass views for its toolbar and instructions.

The annotation model, region gestures and drawing algorithms are application content. Apple does not expose a public complete screenshot annotation editor. Core Graphics draws shapes and text, and Core Image supplies pixelation and inversion. Native UndoManager records editing operations. The text editor uses NSTextView for Chinese input, selection and system editing commands.

Preview and export share the annotation renderer. Unannotated exports return a direct rectangular CGImage crop without material, scaling or color conversion. Annotated exports draw on the original image, then crop. Rounded preview corners never discard corner pixels in output. Apple ImageIO provides PNG, JPEG, TIFF and BMP encoders. Default redaction samples only the exterior fringe; traditional pixelation is explicitly optional.

PNG exports and clipboard bytes optionally pass through OxiPNG at level 2, with two workers and a two-second search budget, preserving metadata and hidden RGB values. Only a smaller result replaces the original. WebP uses libwebp's lossless encoder with `exact=1` and embeds the original ICC profile; optimization compares methods 0 and 4 and keeps the smaller result. With optimization off, WebP stays lossless and uses method 0. Higher-than-8-bit inputs are rejected for WebP rather than silently reduced. JPEG retains its separate quality setting; TIFF and BMP retain their normal encoders. Encoding runs outside the main actor before saving or publishing clipboard data. No screenshot is sent to an external service.

## Lifecycle, settings and distribution

A normal visible or minimized titled window enables the regular activation policy. Once ordinary windows close, the app becomes an accessory while retaining its NSStatusItem. Capture and nonactivating utility panels do not count as ordinary windows. An enabled menu-bar icon keeps the app resident even when an imported configuration enables idle shutdown. Idle shutdown applies only when the menu-bar icon is hidden.

Settings are JSON in Application Support. The first native launch imports existing Flameshoter INI options, colors and shortcuts; the original stays untouched. Native JSON / INI import and export are supported. Unsupported upload and other-platform integrations are not presented as working controls.

The app retains bundle identifier io.github.Word2VecT.flameshoter and the pinned release certificate. The package audit rejects Qt, third-party frameworks, non-system dynamic libraries, missing Chinese/English localization and incompatible deployment metadata. Tags publish the exact previously tested master artifact. See BUILDING.md for signing and permission continuity checks.

## Icon and qualification

Apple Icon Composer authors the layered icon derived from Flameshot's three SVG flame paths. Xcode actool builds Assets.car and the compatible ICNS. No generated-image experiment ships.

Automated checks cover image pixels, annotation geometry, redaction, migration, shortcuts, native materials, layout, UndoManager, gestures and Dock behavior. Actual macOS 26 runtime and comprehensive accessibility interaction testing remain additional release qualification; use of native APIs does not imply Apple certification.

References:

- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/design/human-interface-guidelines/materials
- https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
- https://developer.apple.com/icon-composer/
