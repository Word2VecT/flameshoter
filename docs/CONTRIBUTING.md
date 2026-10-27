# Contributing

Flameshoter targets macOS 26+ on Apple Silicon. See BUILDING.md for the Swift toolchain and packaging workflow.

Use public Apple APIs and native AppKit controls for UI. Keep material effects in NSGlassEffectView / NSVisualEffectView and export original screenshot pixels separately. Do not add a Qt dependency or imitate Liquid Glass with custom effects.

Run `./scripts/test-native.sh`, `xcrun swift-format format --in-place --recursive Sources tests Package.swift` and `git diff --check` before submitting changes. Add tests for meaningful image, migration or behavior changes. Preserve Chinese and English strings, Flameshot attribution and the GPL license.

Report reproducible issues in https://github.com/Word2VecT/flameshoter/issues with the app version, macOS version, expected behavior and steps to reproduce. Avoid including private screenshots or signing credentials.
