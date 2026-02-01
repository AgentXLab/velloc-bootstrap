#!/usr/bin/env bash
# Runs the Nexus-owned standalone unit-test binaries. Intended to be called from
# CI or from the `Run nexus unit tests` menu entry in build.sh.
#
# By default it builds + runs the FAST binaries (no //chrome/browser link):
#   - custom_browser_nexus_unittests          (lite, pure helpers)
#   - custom_browser_nexus_catalog_unittests  (prompt-holder registry)
#   - custom_browser_nexus_shell_unittests     (shell service, mojo-aware main)
#
# The heavier custom_browser_nexus_browser_unittests binary links
# //chrome/test:test_support_unit (→ //chrome/browser) and is a separate, slower
# tier. Opt in with NEXUS_BROWSER_TESTS=1 to also build + run it. These are all
# Nexus-owned binaries — deliberately NOT linked into Chromium's
# //chrome/test:unit_tests. See docs/agents/nexus-test.md §3.
#
# Usage:
#   scripts/run_nexus_tests.sh [<out-dir-name>] [<gtest-filter>]
#   NEXUS_BROWSER_TESTS=1 scripts/run_nexus_tests.sh [<out-dir-name>] [<filter>]
#
# Defaults:
#   <out-dir-name>     = Debug  (resolves to src/out/Debug)
#   <gtest-filter>     = *      (runs every test in each binary)
#
# Exit code is non-zero when any binary reports a test failure (or is missing).

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_NAME="${1:-Debug}"
GTEST_FILTER="${2:-*}"

OUT_DIR="$SRC_DIR/out/$OUT_NAME"

BINARIES=(
  custom_browser_nexus_unittests
  custom_browser_nexus_catalog_unittests
  custom_browser_nexus_shell_unittests
)
# Opt-in heavier tier (links //chrome/browser via test_support_unit).
if [ "${NEXUS_BROWSER_TESTS:-0}" != "0" ]; then
  BINARIES+=(custom_browser_nexus_browser_unittests)
fi

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

echo "==> autoninja -C $OUT_DIR ${BINARIES[*]} -j 15"
# Don't abort on a non-zero autoninja exit — a flaky compile elsewhere in the
# tree shouldn't block running a binary that actually linked.
build_status=0
autoninja -C "$OUT_DIR" "${BINARIES[@]}" -j 15 || build_status=$?

overall=0
for BIN_NAME in "${BINARIES[@]}"; do
  # Windows vs. *nix binary name.
  if [ -x "$OUT_DIR/${BIN_NAME}.exe" ]; then
    TEST_BIN="$OUT_DIR/${BIN_NAME}.exe"
  elif [ -x "$OUT_DIR/$BIN_NAME" ]; then
    TEST_BIN="$OUT_DIR/$BIN_NAME"
  else
    echo "ERROR: built binary not found: $OUT_DIR/${BIN_NAME}[.exe]" >&2
    echo "       (autoninja exited with $build_status and produced no binary)" >&2
    overall=1
    continue
  fi

  if [ "$build_status" -ne 0 ]; then
    echo "WARN: autoninja exited with $build_status but $TEST_BIN exists." >&2
    echo "      Running tests against the existing binary; results may be stale." >&2
  fi

  echo "==> $TEST_BIN --gtest_filter=$GTEST_FILTER"
  "$TEST_BIN" --gtest_filter="$GTEST_FILTER" || overall=$?
done

exit "$overall"
