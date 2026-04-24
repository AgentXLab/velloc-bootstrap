#!/usr/bin/env bash
# Runs the standalone custom_browser_nexus_unittests binary. Intended to be
# called from CI or from the `Run nexus unit tests` menu entry in build.sh.
#
# Usage:
#   scripts/run_nexus_tests.sh [<out-dir-name>] [<gtest-filter>]
#
# Defaults:
#   <out-dir-name>     = Debug  (resolves to src/out/Debug)
#   <gtest-filter>     = *      (runs every test in the binary)
#
# Exit code is the test binary's exit code (non-zero when any test fails).

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_NAME="${1:-Debug}"
GTEST_FILTER="${2:-*}"

OUT_DIR="$SRC_DIR/out/$OUT_NAME"
BIN_NAME="custom_browser_nexus_unittests"

if [ ! -d "$OUT_DIR" ]; then
  echo "ERROR: out dir not found: $OUT_DIR" >&2
  echo "Build it first, e.g. via ./build.sh and selecting an args file." >&2
  exit 1
fi

if [ -d "$WORKSPACE_DIR/depot_tools" ]; then
  export PATH="$WORKSPACE_DIR/depot_tools:$PATH"
fi

if ! command -v autoninja >/dev/null 2>&1; then
  echo "ERROR: autoninja not found in PATH." >&2
  exit 1
fi

echo "==> autoninja -C $OUT_DIR $BIN_NAME"
autoninja -C "$OUT_DIR" "$BIN_NAME"

# Windows vs. *nix binary name.
if [ -x "$OUT_DIR/${BIN_NAME}.exe" ]; then
  TEST_BIN="$OUT_DIR/${BIN_NAME}.exe"
elif [ -x "$OUT_DIR/$BIN_NAME" ]; then
  TEST_BIN="$OUT_DIR/$BIN_NAME"
else
  echo "ERROR: built binary not found under $OUT_DIR (looked for ${BIN_NAME}[.exe])" >&2
  exit 1
fi

echo "==> $TEST_BIN --gtest_filter=$GTEST_FILTER"
"$TEST_BIN" --gtest_filter="$GTEST_FILTER"
