# Code signing for the Windows installer, via Azure Trusted Signing
# (Artifact Signing). Sourced by build.sh; installer_signing_test.sh
# exercises it against a stub signtool.
#
# OFF by default: an unsigned package is still the normal output until the
# signing identity is validated. Turn it on with `build.sh package --sign`,
# or VELLOC_SIGN=1 in the environment / in signing.local.env.
#
# Configuration (environment, or signing.local.env in the workspace root —
# gitignored; copy signing.example.env):
#   VELLOC_SIGN_ENDPOINT   e.g. https://eus.codesigning.azure.net
#   VELLOC_SIGN_ACCOUNT    Trusted Signing account name
#   VELLOC_SIGN_PROFILE    certificate profile name
#   VELLOC_SIGN_DLIB       path to Azure.CodeSigning.Dlib.dll (x64)
#   VELLOC_SIGNTOOL        optional; default = newest Windows Kits x64 signtool
#   VELLOC_SIGN_TIMESTAMP  optional; default http://timestamp.acs.microsoft.com
# Authentication is the dlib's DefaultAzureCredential: `az login` once
# (or AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET).

VELLOC_SIGN_METADATA=""

velloc_sign_load_config() {
  local config="${VELLOC_SIGN_CONFIG:-$WORKSPACE_DIR/signing.local.env}"
  if [ -f "$config" ]; then
    # The environment outranks the file for the on/off switch, so
    # `VELLOC_SIGN=1 ./build.sh` works with a copied example (VELLOC_SIGN=0).
    local env_sign="${VELLOC_SIGN-}" env_sign_set="${VELLOC_SIGN+x}"
    # shellcheck disable=SC1090
    . "$config"
    if [ -n "$env_sign_set" ]; then
      VELLOC_SIGN="$env_sign"
    fi
  fi
}

velloc_sign_enabled() {
  [ "${VELLOC_SIGN:-0}" = "1" ]
}

velloc_sign_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    echo "$1"
  fi
}

velloc_sign_find_signtool() {
  if [ -n "${VELLOC_SIGNTOOL:-}" ]; then
    echo "$VELLOC_SIGNTOOL"
    return 0
  fi
  local found=""
  local candidate
  shopt -s nullglob
  # Version directories sort lexically in the right order (10.0.22621.0 <
  # 10.0.26100.0), so the last match is the newest SDK.
  for candidate in "/c/Program Files (x86)/Windows Kits/10/bin/"*/x64/signtool.exe; do
    found="$candidate"
  done
  shopt -u nullglob
  if [ -z "$found" ]; then
    return 1
  fi
  echo "$found"
}

# Fails loudly — and before any long build starts — when signing is on but
# not fully configured. A package that silently comes out unsigned is the
# failure this exists to stop.
velloc_sign_check_config() {
  local missing=()
  local name
  for name in VELLOC_SIGN_ENDPOINT VELLOC_SIGN_ACCOUNT VELLOC_SIGN_PROFILE VELLOC_SIGN_DLIB; do
    if [ -z "${!name:-}" ]; then
      missing+=("$name")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: signing is on but not configured; missing: ${missing[*]}"
    echo "       Set them in the environment or in signing.local.env (see signing.example.env)."
    return 1
  fi
  if [ ! -f "$VELLOC_SIGN_DLIB" ]; then
    echo "ERROR: VELLOC_SIGN_DLIB not found: $VELLOC_SIGN_DLIB"
    return 1
  fi
  local signtool=""
  if ! signtool="$(velloc_sign_find_signtool)" || [ ! -f "$signtool" ]; then
    echo "ERROR: signtool.exe not found. Install the Windows SDK or set VELLOC_SIGNTOOL."
    return 1
  fi
  VELLOC_SIGNTOOL="$signtool"

  local out_dir="${VELLOC_SIGN_WORK_DIR:-$OUT_BASE/signing}"
  mkdir -p "$out_dir"
  VELLOC_SIGN_METADATA="$out_dir/metadata.json"
  cat >"$VELLOC_SIGN_METADATA" <<EOF
{
  "Endpoint": "$VELLOC_SIGN_ENDPOINT",
  "CodeSigningAccountName": "$VELLOC_SIGN_ACCOUNT",
  "CertificateProfileName": "$VELLOC_SIGN_PROFILE"
}
EOF
  echo "==> Signing ON: $VELLOC_SIGN_ACCOUNT / $VELLOC_SIGN_PROFILE"
}

# Signs one file, then verifies it against the Windows trust policy.
velloc_sign_file() {
  local file="$1"
  if [ -z "$VELLOC_SIGN_METADATA" ]; then
    echo "ERROR: velloc_sign_file called before velloc_sign_check_config."
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "ERROR: file to sign not found: $file"
    return 1
  fi
  local timestamp="${VELLOC_SIGN_TIMESTAMP:-http://timestamp.acs.microsoft.com}"
  local file_win dlib_win metadata_win
  file_win="$(velloc_sign_win_path "$file")"
  dlib_win="$(velloc_sign_win_path "$VELLOC_SIGN_DLIB")"
  metadata_win="$(velloc_sign_win_path "$VELLOC_SIGN_METADATA")"

  echo "==> signtool sign $file_win"
  MSYS2_ARG_CONV_EXCL="*" "$VELLOC_SIGNTOOL" sign /v /debug /fd SHA256 \
    /tr "$timestamp" /td SHA256 \
    /dlib "$dlib_win" /dmdf "$metadata_win" \
    "$file_win" || {
    echo "ERROR: signing failed for $file_win"
    return 1
  }
  MSYS2_ARG_CONV_EXCL="*" "$VELLOC_SIGNTOOL" verify /pa "$file_win" || {
    echo "ERROR: signature verification failed for $file_win"
    return 1
  }
}

# Lists the payload binaries — every .exe/.dll that chrome.release packs into
# chrome.7z and that exists in the build output — one absolute path per line.
# chrome.release is the installer's own manifest, so the signed set cannot
# drift from the shipped set. Paths in it are relative to the out dir.
velloc_sign_list_payload() {
  local release_file="$1"
  local out_dir="$2"
  local line rel
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*|'['*) continue ;;
    esac
    rel="${line%%:*}"
    rel="${rel//'\'//}"
    case "$rel" in
      *.exe|*.EXE|*.dll|*.DLL) ;;
      *) continue ;;
    esac
    if [ -f "$out_dir/$rel" ]; then
      echo "$out_dir/$rel"
    fi
  done <"$release_file"
}

# True when the file already carries a valid Authenticode signature — ours
# from an earlier run, or a vendor's (Widevine, d3dcompiler_47, dxcompiler).
velloc_sign_is_signed() {
  local file_win
  file_win="$(velloc_sign_win_path "$1")"
  MSYS2_ARG_CONV_EXCL="*" "$VELLOC_SIGNTOOL" verify /pa /q "$file_win" >/dev/null 2>&1
}

# Signs every unsigned payload binary plus setup.exe (packed separately as
# setup.ex_). Run between building mini_installer and rebuilding it: the
# signed files are newer than chrome.7z, so the rebuild repacks them.
velloc_sign_payload() {
  local release_file="$1"
  local out_dir="$2"
  local files=()
  local file
  while IFS= read -r file; do
    files+=("$file")
  done < <(velloc_sign_list_payload "$release_file" "$out_dir")
  if [ -f "$out_dir/setup.exe" ]; then
    files+=("$out_dir/setup.exe")
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    echo "ERROR: no payload binaries found in $out_dir (manifest $release_file)."
    return 1
  fi
  local signed=0 skipped=0
  for file in "${files[@]}"; do
    if velloc_sign_is_signed "$file"; then
      skipped=$((skipped + 1))
      continue
    fi
    velloc_sign_file "$file" || return 1
    signed=$((signed + 1))
  done
  echo "==> Payload: signed $signed, already signed $skipped"
}
