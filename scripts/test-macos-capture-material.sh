#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QT_ROOT="${FLAMESHOTER_QT_ROOT:?Set FLAMESHOTER_QT_ROOT to the Qt installation}"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/flameshoter-material-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
/usr/bin/xcrun clang++ -std=c++20 -fobjc-arc -mmacosx-version-min=26.0 \
  -I "$SOURCE_ROOT/src" -F "$QT_ROOT/lib" \
  -I "$QT_ROOT/lib/QtCore.framework/Headers" \
  -I "$QT_ROOT/lib/QtGui.framework/Headers" \
  -I "$QT_ROOT/lib/QtWidgets.framework/Headers" \
  "$SOURCE_ROOT/src/platform/macos/capturematerial.mm" "$SOURCE_ROOT/tests/macos/capturematerial.mm" \
  -framework AppKit -framework QtWidgets -framework QtGui -framework QtCore \
  -Wl,-rpath,"$QT_ROOT/lib" -o "$TEST_ROOT/material-test"
"$TEST_ROOT/material-test"
