#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SOURCE_ROOT"
BUILD_ROOT="${FLAMESHOTER_BUILD_DIR:-$(getconf DARWIN_USER_CACHE_DIR)/flameshoter-swift-build}"
CONFIGURATION="${FLAMESHOTER_CONFIGURATION:-release}"
swift build --configuration "$CONFIGURATION" --arch arm64 --build-path "$BUILD_ROOT" --product Flameshoter
if [[ "${1:-}" == '--package' ]]; then
  BIN_ROOT=$(swift build --configuration "$CONFIGURATION" --arch arm64 --build-path "$BUILD_ROOT" --show-bin-path)
  VERSION=$(cat VERSION)
  python3 scripts/package-macos.py --binary "$BIN_ROOT/Flameshoter" \
    --out "$SOURCE_ROOT/dist/Flameshoter-$VERSION-macos-arm64.zip" "${@:2}"
fi
