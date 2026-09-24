#!/usr/bin/env bash
# Mac O' Blox installer: Darling, the tools the launcher needs, and the
# launcher itself with its app menu entry. Run it again to update.
#
#   curl -fsSL https://raw.githubusercontent.com/narezy/MacOBlox/main/install.sh | bash
#
# Everything runs inside main(), called on the last line, so a download cut
# off halfway does nothing.

set -euo pipefail

REPO=https://github.com/narezy/MacOBlox.git
DIR=${XDG_DATA_HOME:-$HOME/.local/share}/MacOBlox

say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

install_arch() {
  # Only packages that are not installed at all: asking pacman for an
  # installed but outdated one (pipewire-audio 1.6.8 with 1.6.9 in the repo)
  # makes it a partial upgrade that breaks on pinned dependencies.
  local wanted=(git base-devel clang lld unzip python python-gobject gtk4 libadwaita)
  command -v pw-cat >/dev/null || wanted+=(pipewire-audio)
  local missing
  missing=$(pacman -T "${wanted[@]}" || true)
  if [[ -n $missing ]]; then
    say "Installing tools (pacman): $(echo $missing)"
    # shellcheck disable=SC2086
    sudo pacman -S --needed --noconfirm $missing ||
      die "pacman could not install them. Update the system with 'sudo pacman -Syu' and run this again."
  fi
  command -v darling >/dev/null && return
  say "Installing Darling from the AUR (darling-bin)"
  if command -v paru >/dev/null; then
    paru -S --needed --noconfirm --skipreview darling-bin
  elif command -v yay >/dev/null; then
    yay -S --needed --noconfirm --answerdiff None --answerclean None darling-bin
  else
    local build
    build=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/darling-bin.git "$build/darling-bin"
    (cd "$build/darling-bin" && makepkg -si --noconfirm)
    rm -rf "$build"
  fi
}

install_debian() {
  say "Installing tools (apt)"
  sudo apt-get update
  sudo apt-get install -y git curl unzip clang lld pipewire-bin python3 python3-gi \
    gir1.2-gtk-4.0 gir1.2-adw-1
  command -v darling >/dev/null && return
  # The release page redirects to the newest tag, v0.1.YYYYMMDD; its Debian
  # packages (built for Ubuntu 24.04) come as debs_YYYYMMDD.zip.
  local tag build
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/darlinghq/darling/releases/latest)
  tag=${tag##*/}
  say "Installing Darling $tag"
  build=$(mktemp -d)
  curl -fL --progress-bar -o "$build/debs.zip" \
    "https://github.com/darlinghq/darling/releases/download/$tag/debs_${tag##*.}.zip"
  unzip -q "$build/debs.zip" -d "$build"
  sudo apt-get install -y "$build"/debs_*/*.deb
  rm -rf "$build"
}

install_fedora() {
  say "Installing tools (dnf)"
  sudo dnf install -y git clang lld unzip pipewire-utils python3-gobject gtk4 libadwaita
}

main() {
  # Package managers may ask questions; with curl | bash stdin is this script.
  if [[ ! -t 0 ]] && (: </dev/tty) 2>/dev/null; then exec </dev/tty; fi
  [[ $(uname -m) == x86_64 ]] || die "Darling runs only on x86_64."
  [[ $EUID -ne 0 ]] || die "Run this as your user, not root. sudo is used when needed."
  [[ -r /etc/os-release ]] && . /etc/os-release
  local family=" ${ID:-} ${ID_LIKE:-} "
  case "$family" in
    *" arch "*) install_arch ;;
    *" debian "* | *" ubuntu "*) install_debian ;;
    *" fedora "*) install_fedora ;;
    *)
      # Derivatives that do not say what they are based on (LeagueArchy has
      # no ID_LIKE): go by the package manager.
      if command -v pacman >/dev/null; then install_arch
      elif command -v apt-get >/dev/null; then install_debian
      elif command -v dnf >/dev/null; then install_fedora
      else say "Unknown distribution, install Darling, clang, lld, unzip, PipeWire, PyGObject, GTK 4 and libadwaita yourself"
      fi ;;
  esac
  for tool in clang ld.lld unzip; do
    command -v "$tool" >/dev/null || die "$tool is not installed. Install clang, lld and unzip with your package manager and run this again."
  done
  command -v darling >/dev/null ||
    die "Darling is not installed. Build it with https://docs.darlinghq.org/build-instructions.html and run this again."

  if [[ -d $DIR/.git ]]; then
    say "Updating Mac O' Blox"
    git -C "$DIR" pull --ff-only
  else
    say "Downloading Mac O' Blox"
    git clone --depth 1 "$REPO" "$DIR"
  fi
  say "Building the Roblox shim"
  local output
  if ! output=$("$DIR/build_debug_shim.sh" 2>&1); then
    printf '%s\n' "$output" >&2
    die "Could not build the shim. Send the text above to the Discord: https://discord.gg/bpX9rTttCa"
  fi
  "$DIR/launcher/install.sh"
  say "Done. Open Mac O' Blox from the app menu, press Install Roblox, then Play."
}

main "$@"
