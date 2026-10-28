<p align="center"><img src="packaging/macos/Flameshoter-Default.png" width="160" alt="Flameshoter"></p>

# Flameshoter

A macOS menu-bar screenshot and annotation app based on [Flameshot](https://github.com/flameshot-org/flameshot), with English, Simplified Chinese and native Apple Liquid Glass.

[简体中文](README.md) · [Downloads](https://github.com/Word2VecT/flameshoter/releases)

## Install

Requires Apple Silicon and macOS 26 or newer.

```sh
brew install --cask Word2VecT/tap/flameshoter
brew upgrade --cask flameshoter
```

If macOS blocks the first launch, allow it in System Settings → Privacy & Security. Grant Screen Recording access when first capturing.

## Use

- The app stays in the menu bar. Click the flame icon or press **⌘⇧X** to capture.
- Select a region and annotate it. Press **Space** for colors, line widths and text options.
- **⌘C** copies, **⌘S** saves, **⌘⇧S** opens the system share sheet, and **Esc** cancels.
- Open Settings from the menu bar to change the language, tools and shortcuts.

Run `flameshoter --help` for command-line options.

## License

[GPL-3.0-or-later](LICENSE) · [Third-party notices](THIRD_PARTY.md) · [Building](docs/BUILDING.md)
