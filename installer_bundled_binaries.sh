# Stages the third-party binaries the NSIS wrapper installs next to
# chrome.exe (today: ripgrep). Sourced by build.sh after installer_signing.sh;
# installer_bundled_binaries_test.sh exercises it against a stub signtool.
#
# The vendored file (src/custom_browser/installer/bundled/rg.exe) is the
# unsigned upstream binary and is never modified: it is copied into the out
# dir, checked against the pin below, and the COPY is signed with the same
# certificate as the rest of the package (velloc_sign_file).

# SHA-256 of the unsigned upstream rg.exe (ripgrep 14.1.1, x86_64 MSVC).
# Bump together with src/custom_browser/installer/bundled/README.md.
VELLOC_BUNDLED_RG_SHA256="f162b54de2adfc72d78adb1dbada2dedda111ae0a5e2f6e9500f4f909664c5d2"

# Set by velloc_stage_bundled_rg: the staged (and, when signing, signed) copy.
VELLOC_BUNDLED_RG_PATH=""

# velloc_stage_bundled_rg <vendored rg.exe> <stage dir>
velloc_stage_bundled_rg() {
  local source="$1" stage_dir="$2"
  VELLOC_BUNDLED_RG_PATH=""
  if [ ! -f "$source" ]; then
    echo "ERROR: bundled ripgrep not found at $source."
    return 1
  fi
  local actual
  actual="$(sha256sum <"$source" | cut -d' ' -f1)"
  if [ "$actual" != "$VELLOC_BUNDLED_RG_SHA256" ]; then
    echo "ERROR: $source has SHA-256 $actual, expected $VELLOC_BUNDLED_RG_SHA256."
    return 1
  fi
  mkdir -p "$stage_dir" || return 1
  local staged="$stage_dir/rg.exe"
  # A fresh copy every run: a copy signed by an earlier run would be signed
  # twice (appended signature) or, with signing off, ship signed by accident.
  rm -f "$staged"
  cp "$source" "$staged" || return 1
  if velloc_sign_enabled; then
    echo "==> sign bundled ripgrep"
    velloc_sign_file "$staged" || return 1
  fi
  VELLOC_BUNDLED_RG_PATH="$staged"
}
