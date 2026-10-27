#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QT_ROOT="${FLAMESHOTER_QT_ROOT:-}"
if [[ -z "$QT_ROOT" ]]; then
  echo 'Set FLAMESHOTER_QT_ROOT to an official Qt installation. See docs/BUILDING.md.' >&2
  exit 1
fi
BUILD_ROOT="${FLAMESHOTER_BUILD_DIR:-$SOURCE_ROOT/build}"
cmake -S "$SOURCE_ROOT" -B "$BUILD_ROOT" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_PREFIX_PATH="$QT_ROOT" \
  -DQt6_DIR="$QT_ROOT/lib/cmake/Qt6" -DFLAMESHOTER_DEPLOY_QT=OFF \
  -DDISABLE_UPDATE_CHECKER=ON -DUSE_MONOCHROME_ICON=ON
cmake --build "$BUILD_ROOT" --parallel
if [[ "${1:-}" == '--package' ]]; then
  VERSION=$(sed -n 's/^set(FLAMESHOT_VERSION \([0-9.]*\)).*/\1/p' "$SOURCE_ROOT/CMakeLists.txt")
  python3 "$SOURCE_ROOT/scripts/package-macos.py" --app "$BUILD_ROOT/src/Flameshoter.app" \
    --qt "$QT_ROOT" --out "$SOURCE_ROOT/dist/Flameshoter-$VERSION-macos-arm64.zip"
fi
