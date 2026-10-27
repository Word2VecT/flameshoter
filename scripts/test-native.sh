#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/flameshoter-native-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
SWIFT_BIN=$(xcrun --find swift)
TEST_PLUGIN="$(dirname "$SWIFT_BIN")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=()
# Swift 6.4's CLT build engine does not discover this bundled plugin itself.
if [[ -f "$TEST_PLUGIN" ]]; then args+=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN"); fi
cd "$SOURCE_ROOT"
BUILD_ROOT="${FLAMESHOTER_TEST_BUILD_DIR:-$(getconf DARWIN_USER_CACHE_DIR)/flameshoter-swift-tests}"
FLAMESHOTER_TEST_CONFIG="$TEST_ROOT" swift test --scratch-path "$BUILD_ROOT" "${args[@]}"
