# Flameshoter

A macOS screenshot and annotation app derived from [Flameshot](https://github.com/flameshot-org/flameshot), with native AppKit Liquid Glass controls and Chinese/English UI.

Requires Apple Silicon and macOS 26 or later for the initial binary release.

```sh
brew install --cask Word2VecT/tap/flameshoter
```

Use ⌘⇧X to capture, drag a region, annotate, then ⌘C to copy or ⌘S to save. Space opens the native tool inspector. `flameshoter gui`, `full`, `screen`, `launcher`, and `config` retain the upstream CLI model.

Seven native settings pages cover general behavior, capture, toolbar selection, colors, saving, annotation parameters and all capture shortcuts. Import/export existing Flameshot INI files. Choose Simplified Chinese, English or the system language in General settings.

The icon retains Flameshot's three flame shapes and colors. It is authored as a layered Apple Icon Composer document and compiled with Apple's asset compiler into Assets.car. The app's floating controls use NSGlassEffectView/NSGlassEffectContainerView; standard AppKit controls follow system appearance and accessibility preferences.

Starting with 0.1.2, official releases use one fixed self-signed certificate so updates retain the same signing identity. They are not Apple notarized. Gatekeeper may require you to allow the first launch in System Settings → Privacy & Security. Screen Recording permission is requested when capturing; migrating from earlier ad hoc releases requires granting it once again. No certificate import is needed by users, and no quarantine removal or security bypass is built in.

If Screen Recording is enabled but capture still fails, use **Settings → Capture → Repair Screen Recording authorization…** and grant access to the restarted app. This resets only Flameshoter's Screen Recording record; do not reset it during normal upgrades.

See [building and releasing](docs/BUILDING.md), [design](docs/DESIGN.md), and [third-party notices](THIRD_PARTY.md). GPL-3.0-or-later; upstream attribution is preserved. Initial upstream revision: `da34dcb1b296bd2e3bc589767abbe788084215ae`.
