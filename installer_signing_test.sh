#!/usr/bin/env bash
# Tests for installer_signing.sh against a stub signtool.
#   bash installer_signing_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# Stub signtool: records each invocation's argv, one line per call; exits
# with $STUB_EXIT (default 0).
STUB="$TMP/signtool.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
# `verify /pa /q <file>` is the "already signed?" probe: signed only when the
# file is named in $STUB_SIGNED.
if [ "$1" = verify ] && [ "$3" = /q ]; then
  grep -qxF "$4" "${STUB_SIGNED:-/dev/null}" 2>/dev/null
  exit $?
fi
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUB"
export STUB_LOG="$TMP/calls.log"
touch "$TMP/Azure.CodeSigning.Dlib.dll" "$TMP/Setup.exe"

# Each case runs in a fresh subshell with a clean signing environment.
run_case() {
  (
    unset VELLOC_SIGN VELLOC_SIGN_ENDPOINT VELLOC_SIGN_ACCOUNT VELLOC_SIGN_PROFILE \
      VELLOC_SIGN_DLIB VELLOC_SIGNTOOL VELLOC_SIGN_TIMESTAMP VELLOC_SIGN_CONFIG
    WORKSPACE_DIR="$TMP/workspace"
    OUT_BASE="$TMP/out"
    VELLOC_SIGN_WORK_DIR="$TMP/signing"
    # shellcheck source=installer_signing.sh
    . "$HERE/installer_signing.sh"
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

# 1. Signing is off unless asked for — the unsigned package stays the default.
case_default_off() { ! velloc_sign_enabled; }
run_case case_default_off && pass "signing off by default" || fail "signing off by default"

case_on() { VELLOC_SIGN=1; velloc_sign_enabled; }
run_case case_on && pass "VELLOC_SIGN=1 turns signing on" || fail "VELLOC_SIGN=1 turns signing on"

# 2. The local config file is sourced and can flip the switch.
case_config_file() {
  VELLOC_SIGN_CONFIG="$TMP/signing.local.env"
  printf 'VELLOC_SIGN=1\nVELLOC_SIGN_ACCOUNT=from-file\n' >"$VELLOC_SIGN_CONFIG"
  velloc_sign_load_config
  velloc_sign_enabled && [ "$VELLOC_SIGN_ACCOUNT" = from-file ]
}
run_case case_config_file && pass "signing.local.env is loaded" || fail "signing.local.env is loaded"

case_env_beats_config() {
  VELLOC_SIGN=1
  VELLOC_SIGN_CONFIG="$TMP/signing.local.env"
  printf 'VELLOC_SIGN=0
VELLOC_SIGN_ACCOUNT=from-file
' >"$VELLOC_SIGN_CONFIG"
  velloc_sign_load_config
  velloc_sign_enabled && [ "$VELLOC_SIGN_ACCOUNT" = from-file ]
}
run_case case_env_beats_config && pass "env VELLOC_SIGN outranks the file" || fail "env VELLOC_SIGN outranks the file"

case_config_absent() { velloc_sign_load_config; ! velloc_sign_enabled; }
run_case case_config_absent && pass "missing config file is not an error" || fail "missing config file is not an error"

# 3. Incomplete configuration fails loudly and names what is missing.
case_missing() {
  VELLOC_SIGN_ACCOUNT=velloc-signing
  local out
  if out="$(velloc_sign_check_config)"; then return 1; fi
  [[ "$out" == *VELLOC_SIGN_ENDPOINT* && "$out" == *VELLOC_SIGN_PROFILE* \
    && "$out" == *VELLOC_SIGN_DLIB* && "$out" != *"missing: VELLOC_SIGN_ACCOUNT"* ]]
}
run_case case_missing && pass "missing settings are reported" || fail "missing settings are reported"

case_missing_dlib() {
  configure
  VELLOC_SIGN_DLIB="$TMP/nope.dll"
  ! velloc_sign_check_config >/dev/null
}
run_case case_missing_dlib && pass "absent dlib fails" || fail "absent dlib fails"

case_missing_signtool() {
  configure
  VELLOC_SIGNTOOL="$TMP/no-signtool.exe"
  ! velloc_sign_check_config >/dev/null
}
run_case case_missing_signtool && pass "absent signtool fails" || fail "absent signtool fails"

# 4. A complete configuration writes the dlib metadata file.
case_metadata() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  grep -q '"Endpoint": "https://eus.codesigning.azure.net"' "$VELLOC_SIGN_METADATA" \
    && grep -q '"CodeSigningAccountName": "velloc-signing"' "$VELLOC_SIGN_METADATA" \
    && grep -q '"CertificateProfileName": "velloc-public"' "$VELLOC_SIGN_METADATA"
}
run_case case_metadata && pass "metadata.json written" || fail "metadata.json written"

# 5. Signing calls signtool sign through the dlib, then verifies.
case_sign() {
  configure
  rm -f "$STUB_LOG"
  velloc_sign_check_config >/dev/null || return 1
  velloc_sign_file "$TMP/Setup.exe" >/dev/null || return 1
  [ "$(wc -l <"$STUB_LOG")" -eq 2 ] || return 1
  local sign verify
  sign="$(sed -n 1p "$STUB_LOG")"
  verify="$(sed -n 2p "$STUB_LOG")"
  [[ "$sign" == "sign "* && "$sign" == *"/fd SHA256"* && "$sign" == *"/td SHA256"* \
    && "$sign" == *"/tr http://timestamp.acs.microsoft.com"* \
    && "$sign" == *"/dlib "*Azure.CodeSigning.Dlib.dll* \
    && "$sign" == *"/dmdf "*metadata.json* && "$sign" == *Setup.exe ]] || return 1
  [[ "$verify" == "verify /pa "*Setup.exe ]]
}
run_case case_sign && pass "sign then verify" || fail "sign then verify"

case_timestamp_override() {
  configure
  VELLOC_SIGN_TIMESTAMP=http://ts.example
  rm -f "$STUB_LOG"
  velloc_sign_check_config >/dev/null && velloc_sign_file "$TMP/Setup.exe" >/dev/null || return 1
  grep -q '/tr http://ts.example' "$STUB_LOG"
}
run_case case_timestamp_override && pass "timestamp override" || fail "timestamp override"

# 6. A signtool failure propagates — no silently unsigned package.
case_sign_fails() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  ! STUB_EXIT=1 velloc_sign_file "$TMP/Setup.exe" >/dev/null
}
run_case case_sign_fails && pass "signtool failure propagates" || fail "signtool failure propagates"

case_sign_unconfigured() { ! velloc_sign_file "$TMP/Setup.exe" >/dev/null; }
run_case case_sign_unconfigured && pass "sign before check fails" || fail "sign before check fails"

case_sign_missing_file() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  ! velloc_sign_file "$TMP/absent.exe" >/dev/null
}
run_case case_sign_missing_file && pass "missing target fails" || fail "missing target fails"

# 7. Payload: the signed set is chrome.release's .exe/.dll entries that exist.
make_payload_fixture() {
  PAYLOAD_OUT="$TMP/payload_out"
  rm -rf "$PAYLOAD_OUT"
  mkdir -p "$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64"
  touch "$PAYLOAD_OUT/chrome.exe" "$PAYLOAD_OUT/chrome.dll" "$PAYLOAD_OUT/chrome_elf.dll" \
    "$PAYLOAD_OUT/resources.pak" "$PAYLOAD_OUT/setup.exe" \
    "$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll"
  RELEASE="$TMP/chrome.release"
  printf '%s\r\n' \
    '# comment: chrome.exe: %(ChromeDir)s\' \
    '[GENERAL]' \
    'chrome.exe: %(ChromeDir)s\' \
    'chrome.dll: %(VersionDir)s\' \
    'chrome_elf.dll: %(VersionDir)s\' \
    'not_built.dll: %(VersionDir)s\' \
    'resources.pak: %(VersionDir)s\' \
    'WidevineCdm\_platform_specific\win_x64\widevinecdm.dll: %(VersionDir)s\WidevineCdm\' \
    'WidevineCdm\_platform_specific\win_x64\widevinecdm.dll.sig: %(VersionDir)s\WidevineCdm\' \
    '' \
    '[HIDPI]' \
    'chrome_100_percent.pak: %(VersionDir)s\' >"$RELEASE"
}

case_list_payload() {
  make_payload_fixture
  local got expected
  got="$(velloc_sign_list_payload "$RELEASE" "$PAYLOAD_OUT")"
  expected="$PAYLOAD_OUT/chrome.exe
$PAYLOAD_OUT/chrome.dll
$PAYLOAD_OUT/chrome_elf.dll
$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll"
  [ "$got" = "$expected" ] || { echo "got: $got"; return 1; }
}
run_case case_list_payload && pass "payload list from chrome.release" || fail "payload list from chrome.release"

# Signs every unsigned payload binary plus setup.exe; skips already-signed
# ones (a vendor's, or ours from a previous run).
case_sign_payload() {
  make_payload_fixture
  configure
  velloc_sign_check_config >/dev/null || return 1
  export STUB_SIGNED="$TMP/already_signed.txt"
  velloc_sign_win_path "$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll" >"$STUB_SIGNED"
  rm -f "$STUB_LOG"
  local out
  out="$(velloc_sign_payload "$RELEASE" "$PAYLOAD_OUT")" || { echo "$out"; return 1; }
  [[ "$out" == *"signed 4, already signed 1"* ]] || { echo "$out"; return 1; }
  local f
  for f in chrome.exe chrome.dll chrome_elf.dll setup.exe; do
    grep -q "^sign .*$f\$" "$STUB_LOG" || { echo "not signed: $f"; return 1; }
  done
  ! grep -q '^sign .*widevinecdm.dll$' "$STUB_LOG"
}
run_case case_sign_payload && pass "payload signed, signed ones skipped" || fail "payload signed, signed ones skipped"

case_sign_payload_fails() {
  make_payload_fixture
  configure
  velloc_sign_check_config >/dev/null || return 1
  ! STUB_EXIT=1 velloc_sign_payload "$RELEASE" "$PAYLOAD_OUT" >/dev/null
}
run_case case_sign_payload_fails && pass "payload signing failure propagates" || fail "payload signing failure propagates"

case_sign_payload_empty() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  mkdir -p "$TMP/empty_out"
  printf 'chrome.dll: %%(VersionDir)s\\\n' >"$TMP/empty.release"
  ! velloc_sign_payload "$TMP/empty.release" "$TMP/empty_out" >/dev/null
}
run_case case_sign_payload_empty && pass "empty payload fails" || fail "empty payload fails"

# 8. build.sh still parses with the wiring in place.
bash -n "$HERE/build.sh" && pass "build.sh parses" || fail "build.sh parses"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
