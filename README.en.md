<div align="center">
  <img src="packaging/macos/Flameshoter-Default.png" width="128" alt="Flameshoter">
  <h1>Flameshoter</h1>
  <p>Simple screenshot capture and annotation for macOS.</p>
  <p>
    <a href="https://github.com/Word2VecT/flameshoter/actions/workflows/macos.yml"><img src="https://img.shields.io/github/actions/workflow/status/Word2VecT/flameshoter/macos.yml?branch=master&amp;label=macOS" alt="macOS build"></a>
    <a href="https://github.com/Word2VecT/flameshoter/releases"><img src="https://img.shields.io/github/v/release/Word2VecT/flameshoter" alt="Latest release"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/Word2VecT/flameshoter" alt="License"></a>
  </p>
  <p><a href="README.md">简体中文</a></p>
</div>

## Index

- [Features](#features)
- [Usage](#usage)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Installation](#installation)
- [Compilation](#compilation)
- [License](#license)
- [Contribute](#contribute)

## Features

- Region capture, multiple displays and delayed captures.
- In-app annotation: pencil, lines, arrows, shapes, text, numbers and redaction.
- Copy, save, pin and share through the macOS share sheet.
- Automatic lossless PNG optimization before saving or copying, plus lossless WebP export. Optimization can be disabled in Settings.
- English, Simplified Chinese and customizable shortcuts.
- Native Apple Liquid Glass interface.

## Usage

Launching Flameshoter keeps it running in the menu bar. Click the flame icon or press **⌘⇧X** to capture, then select a region and annotate it.

You can also use the command line:

```sh
flameshoter gui                    # Region capture
flameshoter gui -d 2000            # Capture after 2 seconds
flameshoter full -p ~/Pictures     # Save a full-screen capture
flameshoter config                 # Open settings
```

Open Settings from the menu bar to change the language, tools and shortcuts. Run `flameshoter --help` for all command-line options.

## Keyboard shortcuts

These are the defaults. Shortcuts can be changed in Settings.

| Keys | Action |
| --- | --- |
| ⌘⇧X | Global region capture |
| P / D / A | Pencil / line / arrow |
| R / C / M | Rectangle / ellipse / highlighter |
| T / N / B | Text / number / redaction |
| ⌘C / ⌘S / ⌘⇧S | Copy / save / share |
| ⌘Z / ⌘⇧Z | Undo / redo |
| ⌘P | Pin capture |
| Space / right-click | Tool settings |
| Esc | Cancel capture |

## Installation

Requires **Apple Silicon and macOS 26 or newer**.

### Homebrew

```sh
brew install --cask Word2VecT/tap/flameshoter
brew upgrade --cask flameshoter
```

### Direct download

Download from [Releases](https://github.com/Word2VecT/flameshoter/releases) and move the app to Applications.

Grant Screen Recording access when first capturing. If macOS blocks the first launch, allow it in System Settings → Privacy & Security.

## Compilation

Use Xcode 27 or newer:

```sh
git clone https://github.com/Word2VecT/flameshoter.git
cd flameshoter
./scripts/build-macos.sh --package
```

See [Building](docs/BUILDING.md) for testing, development and packaging details.

## License

- Code is licensed under [GPL-3.0-or-later](LICENSE).
- The icon derives from Flameshot's artwork and is licensed under the [Free Art License 1.3](licenses/FlameshotLogo-FAL-1.3.txt).
- See [third-party notices](THIRD_PARTY.md) for provenance and license details.

## Contribute

Report bugs or suggest improvements through [Issues](https://github.com/Word2VecT/flameshoter/issues). Pull requests are welcome.

Thanks to the original authors and contributors of [Flameshot](https://github.com/flameshot-org/flameshot).
