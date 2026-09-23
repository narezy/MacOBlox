#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# Output goes to MACOBLOX_BUILD_DIR when the sources are read-only (a package).
build_dir=${MACOBLOX_BUILD_DIR:-$project_dir/build}
# Packages put Darling's macOS root in /usr/libexec, a source build in /usr/local.
sysroot=${DARLING_SYSROOT:-/usr/libexec/darling}
[[ -d $sysroot || -n ${DARLING_SYSROOT:-} || ! -d /usr/local/libexec/darling ]] || sysroot=/usr/local/libexec/darling
mkdir -p "$build_dir"
tmp_output=$(mktemp "$build_dir/.shim.XXXXXX")
trap 'rm -f -- "$tmp_output"' EXIT
clang -target x86_64-apple-darwin -fuse-ld=lld \
  -isysroot "$sysroot" -mmacosx-version-min=11.0 \
  -dynamiclib -fno-objc-arc -Werror=incompatible-function-pointer-types \
  -Wl,-undefined,dynamic_lookup \
  -install_name @rpath/libMacOBloxShims.dylib \
  "$project_dir/libMacOBloxShims.m" "$project_dir/xattr_compat.c" "$project_dir/exit_compat.c" "$project_dir/missing_symbols.c" "$project_dir/net_trace.c" "$project_dir/darling_fixes.c" "$project_dir/xfixes_raw.c" "$project_dir/dns_override.c" "$project_dir/audio_hal.c" "$project_dir/gpu_info.c" "$project_dir/gl_profile.c" "$project_dir/connectx_compat.c" "$project_dir/memory_stats.c" \
  -lobjc -lc++ -lc++abi -framework Foundation -framework AppKit \
  -o "$tmp_output"
mv -- "$tmp_output" "$build_dir/libMacOBloxShims.dylib"
printf 'Built: %s\n' "$build_dir/libMacOBloxShims.dylib"

# Frameworks RobloxPlayer links that Darling does not have (see frameworks/).
# The launcher copies them into the Darling prefix.
for name in CoreML CoreHaptics DeviceCheck; do
  framework="$build_dir/frameworks/$name.framework"
  mkdir -p "$framework/Versions/A"
  clang -target x86_64-apple-darwin -fuse-ld=lld \
    -isysroot "$sysroot" -mmacosx-version-min=11.0 \
    -dynamiclib -fno-objc-arc \
    -install_name "/System/Library/Frameworks/$name.framework/Versions/A/$name" \
    "$project_dir/frameworks/$name.m" -lobjc -framework CoreFoundation \
    -o "$framework/Versions/A/$name"
  ln -sfn A "$framework/Versions/Current"
  ln -sfn "Versions/Current/$name" "$framework/$name"
done
printf 'Built: %s\n' "$build_dir/frameworks"
