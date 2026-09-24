#!/bin/sh
# Mac O' Blox inside the Flatpak: a Darling prefix of its own, Darling
# without root (darling-noroot.c) and the shim built with the package.
export DPREFIX="${DPREFIX:-$XDG_DATA_HOME/darling}"
export MACOBLOX_NOROOT_LIB=/app/lib/macoblox/darling-noroot.so
export MACOBLOX_PID1_DYLIB=/app/lib/macoblox/launchd_pid1.dylib
export MACOBLOX_PREBUILT_SHIM=/app/lib/macoblox/shim
exec python3 /app/share/macoblox/launcher/macoblox-launcher "$@"
