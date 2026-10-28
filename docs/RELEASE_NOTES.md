# Flameshoter 0.2.7

Adds automatic lossless PNG optimization before saving or copying, using embedded OxiPNG. The setting is enabled by default and can be turned off under Saving. Optimized output is used only when smaller; pixel values, transparency and color profiles are preserved.

Adds lossless WebP export in Settings, the save dialog and explicit `.webp` CLI paths. Embedded libwebp preserves hidden RGB values in transparent pixels and includes the original ICC profile. With optimization disabled, WebP remains lossless and uses a faster encoding method. JPEG quality remains a separate setting.

Encoding runs in the background for interactive captures, direct captures and pinned images. The release is self-contained: no additional Homebrew packages or network service are needed to optimize screenshots.
