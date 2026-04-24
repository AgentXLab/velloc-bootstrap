#!/usr/bin/env bash
# Builds and runs the nexus WebUI mocha tests (Layer 2 — pure TS unit tests
# bundled into browser_tests.exe via WebUIMochaBrowserTest).
#
# Usage:
#   scripts/run_nexus_webui_tests.sh [<out-dir-name>] [<gtest-filter>]
#
# Defaults:
#   <out-dir-name>     = Debug  (resolves to src/out/Debug)
#   <gtest-filter>     = NexusWebUITest.*
#
# Note: building browser_tests is heavy. First-time builds take hours;
# incremental relinks are minutes. The script does not skip the build
# step — if the binary is already up-to-date autoninja will be a no-op.
#
# Exit code is the test binary's exit code (non-zero when any test fails).

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_NAME="${1:-Debug}"
GTEST_FILTER="${2:-NexusWebUITest.*}"

OUT_DIR="$SRC_DIR/out/$OUT_NAME"
BIN_NAME="browser_tests"

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
echo "    (first build is multi-hour; incremental should be minutes)"
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
