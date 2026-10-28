# Building and releasing

Release tags promote the successful `master` build for the exact tagged commit. The release job checks `SHA256SUMS` and uploads those same bytes instead of recompiling or signing again. Test the candidate artifact before tagging; Homebrew will install that identical bundle.

Starting with 0.1.2, master builds use one fixed self-signed release certificate. The designated requirement binds the bundle identifier to that certificate, rather than to a build's changing code hash. This lets macOS recognize signed updates as the same application. Migrating from the previous ad hoc signature requires granting Screen Recording once again. This is separate from Gatekeeper trust: the releases are not Apple notarized and may still require Open Anyway on first launch.

The macOS UI requires a macOS 26+ SDK; releases use the Xcode 27 toolchain with a macOS 26 deployment target. Current release binaries are arm64. Xcode is required to compile the layered app icon; Command Line Tools alone can compile the application and reuse compiled icon resources from a previous release while developing.

## Build and test

Install Swift 6.2 or newer with Apple's macOS 26+ SDK. Qt, CMake, Ninja, aqt and Homebrew development libraries are not needed. libwebp 1.6.0 is vendored as C sources and linked statically by SwiftPM. Tests and packaging cache the official OxiPNG 10.2.1 arm64 executable after checking its pinned SHA-256; no Rust toolchain is needed. The packaged app includes the optimizer and works offline without Homebrew libraries or tools.

```sh
./scripts/test-native.sh
./scripts/build-macos.sh
./scripts/build-macos.sh --package
```

Swift caches and signing stages live outside cloud-synced Documents folders, which can add Finder metadata that invalidates code signatures. Override FLAMESHOTER_BUILD_DIR or FLAMESHOTER_TEST_BUILD_DIR when needed. FLAMESHOTER_CONFIGURATION selects the build configuration (default release).

The package script assembles the native app, compiles Flameshoter.icon with Apple's actool, includes English and Chinese resources and third-party licenses, audits runtime dependencies and minimum OS, signs both the optimizer and app, verifies them and executes PNG and WebP fixture exports through the packaged CLI before writing a ZIP.

With Command Line Tools alone, reuse Assets.car and Flameshoter.icns from a previous official release or the **Compile Liquid Glass icon** workflow:

```sh
./scripts/build-macos.sh --package --icon-assets /path/to/icon-resources
```

Alternatively, package a specific compiled executable:

```sh
python3 scripts/package-macos.py --binary /path/to/Flameshoter \
  --icon-assets /path/to/icon-resources --out dist/Flameshoter-native.zip
```

`MACOS_SIGN_IDENTITY` selects the signing certificate by SHA-1 fingerprint; `MACOS_SIGN_KEYCHAIN` optionally supplies its keychain. Without an identity, local development and pull-request builds use ad hoc signing and do not retain authorization across builds. Self-signed builds use no timestamp or hardened runtime. For future Developer ID distribution, pass `--hardened-runtime` to package-macos.py to enable the hardened runtime and secure timestamp, then submit and staple with Apple's notarization tools.

Only the public certificate is committed as `packaging/macos/release-signing.pem`. The private identity is stored in a dedicated local keychain and an encrypted PKCS#12 backup outside the repository. GitHub Actions uses repository secrets `MACOS_SIGNING_P12` (base64-encoded PKCS#12) and `MACOS_SIGNING_PASSWORD`. Keep the same identity for every release; generating a new certificate changes the application's permission identity. Do not commit or distribute the private key. End users do not import or trust the certificate themselves.

Master builds fail when signing credentials are missing. The workflow imports them into an isolated temporary keychain, verifies that the packaged app has the pinned certificate and designated requirement, then deletes the keychain before uploading the artifact. Pull-request builds never import the release key. No Gatekeeper exceptions, trust-store changes or quarantine removal are part of the tap.

Verify two different packaged builds before testing an upgrade:

```sh
python3 scripts/verify-macos-signature.py --app /path/to/new/Flameshoter.app \
  --previous /path/to/previous/Flameshoter.app
```

This checks the signatures, pinned certificate, distinct code hashes and mutually compatible designated requirements. For a runtime check, install the first build at `/Applications/Flameshoter.app`, grant Screen Recording and verify a real capture. Quit the whole process, replace it with the second build at the same path, and capture again without changing privacy settings. Do not use the image fixture for this check. A successful signing check alone is not evidence of actual TCC permission retention.

## Release and tap

The macOS workflow builds and audits every master push. A `v*` tag matching VERSION publishes the ZIP, SHA256 and generated Homebrew cask. Copy the generated Casks/flameshoter.rb into Word2VecT/homebrew-tap and commit it. The generated cask uses an exact release URL and checksum; it never uses `sha256 :no_check` or removes quarantine attributes.

## Test fixtures

`FLAMESHOTER_TEST_IMAGE=/absolute/path/to/fixture.png` replaces desktop capture with that image and avoids asking for Screen Recording access. `FLAMESHOTER_TEST_CONFIG=/absolute/path/to/config-root` isolates test preferences. These are opt-in developer fixtures; normal captures use ScreenCaptureKit. Test with `tests/fixtures/capture.svg`, rendered to PNG, rather than private desktop content.

The audit rejects third-party framework bundles and non-system dynamic libraries. macOS 26 compatibility is checked through deployment metadata; a physical macOS 26 runtime should be included in release qualification in addition to tests on macOS 27.
