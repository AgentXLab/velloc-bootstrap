#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPOT_TOOLS_DIR="$WORKSPACE_DIR/depot_tools"
ARGS_DIR="$WORKSPACE_DIR/args"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_BASE="$SRC_DIR/out"
CUSTOM_BROWSER_TAG_SCRIPT="$WORKSPACE_DIR/scripts/custom_browser_tag.py"
PYTHON_BIN=""

if [ ! -d "$ARGS_DIR" ]; then
  echo "ERROR: args/ not found in workspace root."
  exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: src/ not found. Run ./bootstrap.sh to sync."
  exit 1
fi

if [ -d "$DEPOT_TOOLS_DIR" ]; then
  export PATH="$DEPOT_TOOLS_DIR:$PATH"
fi

NSIS_DIR_WIN='C:\Program Files (x86)\NSIS'
NSIS_DIRS=(
  "$NSIS_DIR_WIN"
  "/c/Program Files (x86)/NSIS"
  "/mnt/c/Program Files (x86)/NSIS"
  "C:/Program Files (x86)/NSIS"
)
if command -v cygpath >/dev/null 2>&1; then
  NSIS_DIRS=(
    "$(cygpath -u "$NSIS_DIR_WIN")"
    "${NSIS_DIRS[@]}"
  )
fi
for nsis_dir in "${NSIS_DIRS[@]}"; do
  if [ -n "$nsis_dir" ] && [ -d "$nsis_dir" ]; then
    export PATH="$nsis_dir:$PATH"
    break
  fi
done

if ! command -v autoninja >/dev/null 2>&1; then
  echo "ERROR: autoninja not found in PATH."
  exit 1
fi

ensure_gn_available() {
  if ! command -v gn >/dev/null 2>&1; then
    echo "ERROR: gn not found in PATH."
    exit 1
  fi

  local gn_bin=""
  local candidates=(
    "$SRC_DIR/buildtools/win/gn.exe"
    "$SRC_DIR/buildtools/win/gn/gn.exe"
  )

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      gn_bin="$candidate"
      break
    fi
  done

  if [ -z "$gn_bin" ]; then
    if command -v gclient >/dev/null 2>&1; then
      echo "==> gn binary missing; running gclient runhooks"
      (cd "$WORKSPACE_DIR" && gclient runhooks)
    else
      echo "ERROR: gn binary missing and gclient not found in PATH."
      exit 1
    fi
  fi

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      return 0
    fi
  done

  echo "ERROR: gn binary still missing after runhooks. Try ./bootstrap.sh then re-run build."
  exit 1
}

ensure_python_available() {
  if [ -n "$PYTHON_BIN" ]; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
    return 0
  fi

  echo "ERROR: python not found in PATH."
  exit 1
}

shopt -s nullglob
arg_files=()
for f in "$ARGS_DIR"/*; do
  [ -f "$f" ] || continue
  arg_files+=("$(basename "$f")")
done
shopt -u nullglob

if [ "${#arg_files[@]}" -eq 0 ]; then
  echo "ERROR: no args files found in $ARGS_DIR."
  exit 1
fi

arg_names=()
for f in "${arg_files[@]}"; do
  base="${f%.*}"
  arg_names+=("$base")
done

default_index=0
for i in "${!arg_names[@]}"; do
  if [ "${arg_names[$i]}" = "Debug" ]; then
    default_index=$i
    break
  fi
done
default_choice=$((default_index + 1))
last_choice=$default_choice
last_arg_choice=$default_choice
last_mini_action=4
VELLOC_MINI_INSTALLER_PATH=""
VELLOC_SETUP_EXE=""
VELLOC_NSIS_INSTALLER_PATH=""

ensure_gn_available

ensure_makensis_available() {
  if command -v makensis >/dev/null 2>&1; then
    return 0
  fi
  if command -v makensis.exe >/dev/null 2>&1; then
    return 0
  fi

  echo "ERROR: makensis not found in PATH. Install NSIS or add makensis to PATH."
  exit 1
}

to_windows_path() {
  local input="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$input"
  else
    echo "$input"
  fi
}

ensure_gn_gen() {
  local out_dir="$1"
  if [ ! -f "$out_dir/build.ninja" ]; then
    echo "==> gn gen $out_dir"
    (
      cd "$SRC_DIR"
      gn gen "$out_dir"
    )
  fi
}

build_chrome() {
  local idx="$1"
  local name="${arg_names[$idx]}"
  local file="${arg_files[$idx]}"
  local out_dir="$OUT_BASE/$name"

  mkdir -p "$out_dir"
  cp -f "$ARGS_DIR/$file" "$out_dir/args.gn"

  ensure_gn_gen "$out_dir"

  echo "==> autoninja -C $out_dir chrome -j 15"
  autoninja -C "$out_dir" chrome -j 15
}

find_arg_index_by_name() {
  local target="$1"
  for i in "${!arg_names[@]}"; do
    if [ "${arg_names[$i]}" = "$target" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

build_mini_installer() {
  echo "==> Select args for mini_installer"
  for i in "${!arg_files[@]}"; do
    printf "%2d) %s\n" $((i + 1)) "${arg_files[$i]}"
  done

  read -r -p "Select args [1-${#arg_files[@]}] (default: $last_arg_choice): " choice
  if [ -z "$choice" ] || ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#arg_files[@]}" ]; then
    choice=$last_arg_choice
    local default_idx=$((choice - 1))
    echo "Invalid choice; defaulting to ${arg_files[$default_idx]}."
  else
    last_arg_choice=$choice
  fi

  local idx=$((choice - 1))
  local file="${arg_files[$idx]}"
  local name="${arg_names[$idx]}"
  local out_dir="$OUT_BASE/$name"

  mkdir -p "$out_dir"
  cp -f "$ARGS_DIR/$file" "$out_dir/args.gn"

  ensure_gn_gen "$out_dir"

  echo "==> autoninja -C $out_dir mini_installer"
  autoninja -C "$out_dir" mini_installer

  local mini_installer_path=""
  if ! mini_installer_path="$(resolve_mini_installer_path "$out_dir")"; then
    return
  fi

  local mini_dir=""
  mini_dir="$(cd "$(dirname "$mini_installer_path")" && pwd)"
  local setup_exe="$mini_dir/setup.exe"
  if [ ! -f "$setup_exe" ]; then
    echo "ERROR: setup.exe not found alongside mini_installer.exe in $mini_dir."
    return
  fi

  echo "==> Post-build actions:"
  echo " 1) uninstall + installer"
  echo " 2) installer"
  echo " 3) uninstall"
  echo " 4) exit"

  read -r -p "Select option [1-4] (default: $last_mini_action): " action
  if [ -z "$action" ] || ! [[ "$action" =~ ^[0-9]+$ ]] || [ "$action" -lt 1 ] || [ "$action" -gt 4 ]; then
    action=$last_mini_action
    echo "Invalid choice; defaulting to last selection."
  else
    last_mini_action=$action
  fi

  case "$action" in
    1)
      if run_setup_uninstall "$setup_exe"; then
        run_mini_installer "$mini_installer_path"
      else
        echo "Skipping installer because uninstall failed."
      fi
      ;;
    2)
      run_mini_installer "$mini_installer_path" || true
      ;;
    3)
      run_setup_uninstall "$setup_exe" || true
      ;;
    4)
      echo "Returning to main menu."
      ;;
  esac
}

build_velloc_mini_installer() {
  local idx=""
  if ! idx="$(find_arg_index_by_name "Velloc")"; then
    echo "ERROR: Velloc args not found in $ARGS_DIR."
    return 1
  fi

  local file="${arg_files[$idx]}"
  local name="${arg_names[$idx]}"
  local out_dir="$OUT_BASE/$name"

  mkdir -p "$out_dir"
  cp -f "$ARGS_DIR/$file" "$out_dir/args.gn"

  ensure_gn_gen "$out_dir"

  echo "==> autoninja -C $out_dir mini_installer"
  autoninja -C "$out_dir" mini_installer

  local mini_installer_path=""
  if ! mini_installer_path="$(resolve_mini_installer_path "$out_dir")"; then
    return 1
  fi

  local mini_dir=""
  mini_dir="$(cd "$(dirname "$mini_installer_path")" && pwd)"
  local setup_exe="$mini_dir/setup.exe"
  if [ ! -f "$setup_exe" ]; then
    echo "ERROR: setup.exe not found alongside mini_installer.exe in $mini_dir."
    return 1
  fi

  VELLOC_MINI_INSTALLER_PATH="$mini_installer_path"
  VELLOC_SETUP_EXE="$setup_exe"
}

build_velloc_nsis_installer() {
  local mini_installer_path="$1"
  local nsis_dir="$SRC_DIR/custom_browser/installer"
  local nsis_script="$nsis_dir/custom_browser_installer_wrapper.nsi"
  local nsis_script_win=""
  local master_prefs="$nsis_dir/master_preferences"
  local product_name="Velloc Browser"
  local output_path="$nsis_dir/${product_name} Setup.exe"

  if [ ! -f "$nsis_script" ]; then
    echo "ERROR: NSIS script not found at $nsis_script."
    return 1
  fi
  if [ ! -f "$master_prefs" ]; then
    echo "ERROR: master_preferences not found at $master_prefs."
    return 1
  fi

  ensure_makensis_available

  local mini_installer_win=""
  local master_prefs_win=""
  mini_installer_win="$(to_windows_path "$mini_installer_path")"
  master_prefs_win="$(to_windows_path "$master_prefs")"
  nsis_script_win="$(to_windows_path "$nsis_script")"

  echo "==> makensis $nsis_script_win"
  (
    cd "$nsis_dir"
    MSYS2_ARG_CONV_EXCL="*" makensis \
      "-DPRODUCT_NAME=$product_name" \
      "-DMINI_INSTALLER_SOURCE=$mini_installer_win" \
      "-DMASTER_PREFERENCES_SOURCE=$master_prefs_win" \
      "$nsis_script_win"
  )

  if [ ! -f "$output_path" ]; then
    echo "ERROR: NSIS output not found at $output_path."
    return 1
  fi

  VELLOC_NSIS_INSTALLER_PATH="$output_path"
}

resolve_mini_installer_path() {
  local out_dir="$1"
  local mini_installer_path=""
  local candidates=(
    "$out_dir/mini_installer.exe"
    "$out_dir/mini_installer/mini_installer.exe"
  )

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      mini_installer_path="$candidate"
      break
    fi
  done

  if [ -z "$mini_installer_path" ]; then
    mini_installer_path="$(find "$out_dir" -maxdepth 3 -name "mini_installer.exe" -print -quit 2>/dev/null || true)"
  fi

  if [ -z "$mini_installer_path" ]; then
    echo "ERROR: mini_installer.exe not found under $out_dir."
    return 1
  fi

  echo "$mini_installer_path"
}

run_setup_uninstall() {
  local setup_exe="$1"
  echo "==> $setup_exe --uninstall"
  if ! "$setup_exe" --uninstall; then
    local status=$?
    echo "WARN: uninstall failed with exit code $status."
    return $status
  fi
  return 0
}

run_mini_installer() {
  local mini_installer_path="$1"
  echo "==> $mini_installer_path"
  if ! "$mini_installer_path"; then
    local status=$?
    echo "WARN: installer failed with exit code $status."
    return $status
  fi
  return 0
}

run_nsis_installer() {
  local nsis_installer_path="$1"
  echo "==> $nsis_installer_path"
  if ! "$nsis_installer_path"; then
    local status=$?
    echo "WARN: NSIS installer failed with exit code $status."
    return $status
  fi
  return 0
}

run_custom_browser_tag() {
  if [ ! -f "$CUSTOM_BROWSER_TAG_SCRIPT" ]; then
    echo "ERROR: tag script not found at $CUSTOM_BROWSER_TAG_SCRIPT."
    return 1
  fi

  ensure_python_available

  echo "==> Release tag options:"
  echo " 1) Create release tag"
  echo " 2) Delete release tag (lists tags, deletes remote)"
  echo " 3) Back"
  read -r -p "Select option [1-3] (default: 1): " action
  if [ -z "$action" ] || ! [[ "$action" =~ ^[0-9]+$ ]] || [ "$action" -lt 1 ] || [ "$action" -gt 3 ]; then
    action=1
    echo "Invalid choice; defaulting to create."
  fi

  if [ "$action" -eq 3 ]; then
    echo "Returning to main menu."
    return 0
  fi

  if [ "$action" -eq 1 ]; then
    if ! "$PYTHON_BIN" "$CUSTOM_BROWSER_TAG_SCRIPT" create; then
      echo "Release tag script failed."
      return 1
    fi
  else
    if ! "$PYTHON_BIN" "$CUSTOM_BROWSER_TAG_SCRIPT" delete; then
      echo "Delete tag script failed."
      return 1
    fi
  fi
}

reinstall_velloc_nsis() {
  echo "==> Reinstall Velloc NSIS"
  build_velloc_mini_installer
  build_velloc_nsis_installer "$VELLOC_MINI_INSTALLER_PATH"

  if run_setup_uninstall "$VELLOC_SETUP_EXE"; then
    run_nsis_installer "$VELLOC_NSIS_INSTALLER_PATH"
  else
    echo "Skipping NSIS installer because uninstall failed."
  fi
}

while true; do
  echo "==> Build options:"
  for i in "${!arg_names[@]}"; do
    printf "%2d) Build %s\n" $((i + 1)) "${arg_names[$i]}"
  done
  menu_build_mini=$(( ${#arg_names[@]} + 1 ))
  menu_reinstall_nsis=$(( ${#arg_names[@]} + 2 ))
  menu_release_tag=$(( ${#arg_names[@]} + 3 ))
  menu_exit=$(( ${#arg_names[@]} + 4 ))
  printf "%2d) Build mini_installer\n" "$menu_build_mini"
  printf "%2d) Reinstall Velloc NSIS\n" "$menu_reinstall_nsis"
  printf "%2d) Release/tag custom browser\n" "$menu_release_tag"
  printf "%2d) Exit\n" "$menu_exit"

  read -r -p "Select option [1-$menu_exit] (default: $last_choice): " choice
  if [ -z "$choice" ] || ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_exit" ]; then
    choice=$last_choice
    echo "Invalid choice; defaulting to last selection."
  else
    last_choice=$choice
  fi

  if [ "$choice" -eq "$menu_exit" ]; then
    echo "Exiting."
    break
  elif [ "$choice" -eq "$menu_release_tag" ]; then
    run_custom_browser_tag
  elif [ "$choice" -eq "$menu_reinstall_nsis" ]; then
    reinstall_velloc_nsis
  elif [ "$choice" -eq "$menu_build_mini" ]; then
    build_mini_installer
  else
    build_chrome $((choice - 1))
  fi
done
