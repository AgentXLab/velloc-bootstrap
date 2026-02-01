#!/usr/bin/env bash
# Runs the nexus_web vitest suite (Layer 2 — pure-TS unit tests for the
# patch_webui/glic browser-actor-tools, settings models, etc.).
#
# Usage:
#   scripts/run_nexus_webui_tests.sh [<vitest-glob-or-file>]
#
# Examples:
#   scripts/run_nexus_webui_tests.sh
#   scripts/run_nexus_webui_tests.sh src/__tests__/observation-parser-parent-index.test.ts
#   scripts/run_nexus_webui_tests.sh observation
#
# Exit code is the vitest exit code (non-zero when any test fails).
#
# History note: an earlier version of this script invoked
# `browser_tests --gtest_filter='NexusWebUITest.*'`, which required a
# multi-hour browser_tests build and never actually ran our pure-TS
# parity tests because chrome://nexus-test/ wasn't a real runtime URL.
# The vitest path imports the patch_webui/glic .ts files directly from
# the filesystem, so it runs in seconds and doesn't need chrome.dll.

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NEXUS_WEB_DIR="$WORKSPACE_DIR/nexus_web"

if [ ! -d "$NEXUS_WEB_DIR" ]; then
  echo "ERROR: nexus_web dir not found: $NEXUS_WEB_DIR" >&2
  exit 1
fi

if [ ! -d "$NEXUS_WEB_DIR/node_modules" ]; then
  echo "==> npm install (node_modules missing in nexus_web)"
  (cd "$NEXUS_WEB_DIR" && npm install)
fi

cd "$NEXUS_WEB_DIR"

# Build a vitest invocation. Pass the user's filter through if one was
# given; otherwise run every test file.
if [ "$#" -gt 0 ]; then
  echo "==> npx vitest run $*"
  exec npx vitest run "$@"
fi

echo "==> npx vitest run"
exec npx vitest run
