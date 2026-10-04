#!/usr/bin/env bash
# Tests for installer_bundled_binaries.sh against a stub signtool.
#   bash installer_bundled_binaries_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# Stub signtool: records each invocation's argv; `sign` appends a marker to
# the file so a test can tell a signed copy from the source.
STUB="$TMP/signtool.sh"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
if [ "$1" = sign ]; then
  for last; do :; done
  printf 'SIGNED' >>"$last"
fi
exit 0
STUBEOF
chmod +x "$STUB"
export STUB_LOG="$TMP/calls.log"
touch "$TMP/Azure.CodeSigning.Dlib.dll"

SOURCE="$TMP/vendor/rg.exe"
mkdir -p "$TMP/vendor"
printf 'upstream-rg' >"$SOURCE"
SOURCE_SHA="$(sha256sum "$SOURCE" | cut -d' ' -f1)"

run_case() {
  (
    unset VELLOC_SIGN VELLOC_SIGN_ENDPOINT VELLOC_SIGN_ACCOUNT VELLOC_SIGN_PROFILE \
      VELLOC_SIGN_DLIB VELLOC_SIGNTOOL VELLOC_SIGN_TIMESTAMP VELLOC_SIGN_CONFIG
    WORKSPACE_DIR="$TMP/workspace"
    OUT_BASE="$TMP/out"
    VELLOC_SIGN_WORK_DIR="$TMP/signing"
    # shellcheck source=installer_signing.sh
    . "$HERE/installer_signing.sh"
    # shellcheck source=installer_bundled_binaries.sh
    . "$HERE/installer_bundled_binaries.sh"
    VELLOC_BUNDLED_RG_SHA256="$SOURCE_SHA"
    "$@"
  )
}

configure() {
  VELLOC_SIGN_ENDPOINT=https://eus.codesigning.azure.net
  VELLOC_SIGN_ACCOUNT=velloc-signing
  VELLOC_SIGN_PROFILE=velloc-public
  VELLOC_SIGN_DLIB="$TMP/Azure.CodeSigning.Dlib.dll"
  VELLOC_SIGNTOOL="$STUB"
}

# 1. The pin in the script matches the vendored binary in the checkout.
VENDORED="$HERE/src/custom_browser/installer/bundled/rg.exe"
if [ -f "$VENDORED" ]; then
  case_pin() {
    . "$HERE/installer_bundled_binaries.sh"
    [ "$(sha256sum "$VENDORED" | cut -d' ' -f1)" = "$VELLOC_BUNDLED_RG_SHA256" ]
  }
  ( case_pin ) && pass "pin matches vendored rg.exe" || fail "pin matches vendored rg.exe"
else
  echo "SKIP: pin check ($VENDORED not present in this checkout)"
fi

# 2. Signing on: the staged copy is signed; the vendored source is untouched.
case_signed() {
  configure
  rm -f "$STUB_LOG"
  velloc_sign_check_config >/dev/null || return 1
  velloc_stage_bundled_rg "$SOURCE" "$TMP/stage1" >/dev/null || return 1
  [ "$VELLOC_BUNDLED_RG_PATH" = "$TMP/stage1/rg.exe" ] || return 1
  grep -q '^sign .*stage1.rg\.exe' "$STUB_LOG" || return 1
  [ "$(cat "$TMP/stage1/rg.exe")" = "upstream-rgSIGNED" ] || return 1
  [ "$(cat "$SOURCE")" = "upstream-rg" ]
}
run_case case_signed && pass "staged copy signed, source untouched" || fail "staged copy signed, source untouched"

# 3. Re-staging starts from the source, never re-signs an old copy.
case_restage() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  velloc_stage_bundled_rg "$SOURCE" "$TMP/stage2" >/dev/null || return 1
  velloc_stage_bundled_rg "$SOURCE" "$TMP/stage2" >/dev/null || return 1
  [ "$(cat "$TMP/stage2/rg.exe")" = "upstream-rgSIGNED" ]
}
run_case case_restage && pass "re-stage signs once" || fail "re-stage signs once"

# 4. Signing off: copied as-is, signtool never called.
case_unsigned() {
  VELLOC_SIGN=0
  configure
  rm -f "$STUB_LOG"
  velloc_stage_bundled_rg "$SOURCE" "$TMP/stage3" >/dev/null || return 1
  [ ! -f "$STUB_LOG" ] && [ "$(cat "$TMP/stage3/rg.exe")" = "upstream-rg" ]
}
run_case case_unsigned && pass "unsigned when signing off" || fail "unsigned when signing off"

# 5. A source that does not match the pin is refused (and nothing is staged).
case_bad_hash() {
  VELLOC_SIGN=0
  VELLOC_BUNDLED_RG_SHA256=0000
  ! velloc_stage_bundled_rg "$SOURCE" "$TMP/stage4" >/dev/null \
    && [ -z "$VELLOC_BUNDLED_RG_PATH" ] && [ ! -f "$TMP/stage4/rg.exe" ]
}
run_case case_bad_hash && pass "hash mismatch refused" || fail "hash mismatch refused"

# 6. A missing source fails.
case_missing() {
  VELLOC_SIGN=0
  ! velloc_stage_bundled_rg "$TMP/nope/rg.exe" "$TMP/stage5" >/dev/null
}
run_case case_missing && pass "missing source fails" || fail "missing source fails"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
