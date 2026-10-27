# Building and releasing

Release tags promote the successful `master` build for the exact tagged commit. The release job checks `SHA256SUMS` and uploads those same bytes instead of recompiling or signing again. Test the candidate artifact before tagging; Homebrew will install that identical bundle. This preserves the tested code identity within a release. Ad hoc signatures still change across application updates; retaining TCC authorization across versions requires a stable Developer ID identity.

The macOS UI requires a macOS 26+ SDK; releases use the Xcode 27 toolchain with a macOS 26 deployment target. Current release binaries are arm64. Xcode is required to compile the layered app icon; Command Line Tools alone can compile the application and use the checked-in Icon Composer PNG/ICNS preview while developing.

## Dependencies

Use official Qt binaries for portable release packages. Some Homebrew dependency bottles may target the build machine's OS even when the app's deployment target is older; the packaging audit deliberately rejects those bundles.

```sh
python3 -m venv .venv
.venv/bin/pip install aqtinstall==3.3.0
.venv/bin/python -m aqt install-qt mac desktop 6.12.0 clang_64 \
  --archives qtbase qtsvg qttools qttranslations qtdeclarative -O .qt
export FLAMESHOTER_QT_ROOT="$PWD/.qt/6.12.0/macos"
brew install cmake ninja
./scripts/build-macos.sh
```

Qt Declarative is needed by Qt 6.12's lrelease build tool. The application itself does not use a QML UI. CMake fetches the three other dependencies at the revisions pinned in CMakeLists.txt.

## Package

```sh
./scripts/build-macos.sh --package
```

The package script compiles Flameshoter.icon using Apple's actool, deploys Qt, includes Chinese catalogs and license notices, verifies runtime dependencies and OS minimums, signs nested code and the app, and executes the packaged CLI before creating a ZIP. Signing takes place outside cloud-synced source folders so Finder metadata cannot invalidate the signature.

For local development without full Xcode, pass a directory containing Assets.car and Flameshoter.icns produced by the **Compile Liquid Glass icon** workflow:

```sh
python3 scripts/package-macos.py --app build/src/Flameshoter.app \
  --qt "$FLAMESHOTER_QT_ROOT" --icon-assets /path/to/icon-resources \
  --out dist/Flameshoter-0.1.0-macos-arm64.zip
```

`MACOS_SIGN_IDENTITY` optionally selects a Developer ID identity; otherwise the script uses an ad hoc signature. A Developer ID signature alone is not notarization. Submit the finished archive with Apple's notarytool and staple the result before publishing if notarized distribution is required. No credentials are committed or embedded in the app.

## Release and tap

The macOS workflow builds and audits every master push. A `v*` tag matching the CMake project version publishes the ZIP, SHA256 and generated Homebrew cask. Copy the generated Casks/flameshoter.rb into Word2VecT/homebrew-tap and commit it. The generated cask uses an exact release URL and checksum; it never uses `sha256 :no_check` or removes quarantine attributes.

## Test fixtures

`FLAMESHOTER_TEST_IMAGE=/absolute/path/to/fixture.png` replaces desktop capture with that image and avoids asking for Screen Recording access. `FLAMESHOTER_TEST_CONFIG=/absolute/path/to/config-root` isolates test preferences. These are opt-in developer fixtures; normal captures use the upstream screen grabber. Test with `tests/fixtures/capture.svg`, rendered to PNG, rather than private desktop content.

The package audit checks both architectures of bundled universal Qt libraries even though the application executable currently targets arm64. macOS 26 compatibility is checked through deployment metadata; a physical macOS 26 runtime should be included in release qualification in addition to tests on macOS 27.
