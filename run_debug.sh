#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# An upgraded kernel can leave the running kernel without loadable modules.
if ! grep -qw overlay /proc/filesystems; then
  running_kernel=$(uname -r)
  if [[ ! -d "/usr/lib/modules/$running_kernel" ]]; then
    printf 'Darling cannot start: OverlayFS is unavailable and modules for running kernel %s are missing.\n' "$running_kernel" >&2
    printf 'Reboot into the installed kernel, then run this script again.\n' >&2
    exit 1
  fi
fi
# Darling's Mesa receives X11 displays. A desktop session may export
# EGL_PLATFORM=wayland, which makes Mesa treat them as Wayland and crash.
export EGL_PLATFORM=x11
"$project_dir/build_debug_shim.sh"
mkdir -p "$project_dir/logs"
log_file=$(mktemp "$project_dir/logs/launch-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")
printf 'Log: %s\n' "$log_file"
# Pass paths as arguments, preserving spaces and non-ASCII names.
# Use the existing Darling prefix, which contains the framework replacements.
set +e
# Forward every MACOBLOX_* variable into the Darling shell as NAME=value
# arguments, so new diagnostic switches need no changes here.
macoblox_env=()
while IFS= read -r name; do
  macoblox_env+=("$name=${!name}")
done < <(compgen -e | grep '^MACOBLOX_' || true)
darling shell /bin/bash -c '
  project_dir=$1
  env_count=$2
  shift 2
  while [ "$env_count" -gt 0 ]; do
    export "$1"
    shift
    env_count=$((env_count - 1))
  done
  app_dir="$project_dir/RobloxPlayer.app/Contents/MacOS"
  cd "$app_dir" || exit
  export DYLD_FORCE_FLAT_NAMESPACE=1
  export DYLD_INSERT_LIBRARIES="$project_dir/build/libMacOBloxShims.dylib"
  export DYLD_LIBRARY_PATH="$project_dir/build:$app_dir"
  exec ./RobloxPlayer "$@"
' macoblox "/Volumes/SystemRoot$project_dir" "${#macoblox_env[@]}" "${macoblox_env[@]}" "$@" 2>&1 | tee "$log_file"
launch_status=${PIPESTATUS[0]}
printf '\nLauncher exit status: %s\n' "$launch_status" | tee -a "$log_file"
exit "$launch_status"
