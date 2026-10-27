#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/flameshoter-dock-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
flags=(-std=c++20 -fobjc-arc -mmacosx-version-min=26.0)
if [[ "${1:-}" == '--baseline' ]]; then flags+=(-DFLAMESHOTER_TEST_WITHOUT_DOCK_POLICY); fi
/usr/bin/xcrun clang++ "${flags[@]}" -I "$SOURCE_ROOT/src" \
  "$SOURCE_ROOT/src/platform/macos/dockicon.mm" "$SOURCE_ROOT/tests/macos/dockicon.mm" \
  -framework AppKit -o "$TEST_ROOT/dock-test"
"$TEST_ROOT/dock-test"
