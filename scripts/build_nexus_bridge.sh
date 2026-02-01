#!/usr/bin/env bash
# Builds the //custom_browser/browser/nexus:bridge source_set.
#
# `scripts/run_nexus_tests.sh` only builds the lite unit-test binary,
# which does NOT depend on :bridge. When you need to verify changes to
# bridge sources (browser_tool.cc, tool_catalog.cc, generated codegen
# .cc files compiled into bridge, etc.) compile cleanly, run this
# script in addition to (or instead of) run_nexus_tests.sh.
#
# Usage:
#   scripts/build_nexus_bridge.sh [<out-dir-name>]
#
# Defaults:
#   <out-dir-name> = Debug   (resolves to src/out/Debug)
#
# Exit code is autoninja's exit code.

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_NAME="${1:-Debug}"
OUT_DIR="$SRC_DIR/out/$OUT_NAME"
TARGET="custom_browser/browser/nexus:bridge"

if [ ! -d "$OUT_DIR" ]; then
  echo "ERROR: out dir not found: $OUT_DIR" >&2
  echo "Build it first via build.sh and selecting an args file." >&2
  exit 1
fi

if [ -d "$WORKSPACE_DIR/depot_tools" ]; then
  export PATH="$WORKSPACE_DIR/depot_tools:$PATH"
fi

if ! command -v autoninja >/dev/null 2>&1; then
  echo "ERROR: autoninja not found in PATH." >&2
  exit 1
fi

echo "==> autoninja -C $OUT_DIR $TARGET -j 15"
autoninja -C "$OUT_DIR" "$TARGET" -j 15
