#!/usr/bin/env bash
# Installs the Mac O’ Blox launcher for the current user: menu entry, icons
# and a `macoblox` command. Run again after moving the project folder.
set -euo pipefail
launcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(dirname -- "$launcher_dir")
data_home=${XDG_DATA_HOME:-$HOME/.local/share}

for size in 16 22 24 32 48 64 128 256 512; do
  install -Dm644 "$project_dir/branding/icons/macoblox-$size.png" \
    "$data_home/icons/hicolor/${size}x${size}/apps/macoblox.png"
done

install -d "$HOME/.local/bin"
ln -sf "$launcher_dir/macoblox-launcher" "$HOME/.local/bin/macoblox"

install -d "$data_home/applications"
cat > "$data_home/applications/xyz.narez.MacOBlox.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Mac O’ Blox
Comment=Run the macOS Roblox client on Linux through Darling
Comment[ru]=Запуск клиента Roblox для macOS на Linux через Darling
GenericName=Roblox launcher
GenericName[ru]=Лаунчер Roblox
Exec=$launcher_dir/macoblox-launcher
Icon=macoblox
Terminal=false
Categories=Game;
Keywords=roblox;darling;
StartupNotify=true
DESKTOP

# Roblox Studio (Windows version through Wine), also the handler of the
# roblox-studio: links and of roblox-studio-auth: that signs Studio in.
cat > "$data_home/applications/xyz.narez.MacOBlox.Studio.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Roblox Studio (Mac O’ Blox)
Comment=Roblox Studio through Wine
Comment[ru]=Roblox Studio через Wine
Exec=$launcher_dir/macoblox-launcher --studio %u
Icon=macoblox
Terminal=false
Categories=Development;
MimeType=x-scheme-handler/roblox-studio;x-scheme-handler/roblox-studio-auth;application/x-roblox-place;
StartupWMClass=robloxstudiobeta.exe
DESKTOP
if command -v xdg-mime >/dev/null; then
  for type in x-scheme-handler/roblox-studio x-scheme-handler/roblox-studio-auth; do
    xdg-mime default xyz.narez.MacOBlox.Studio.desktop "$type"
  done
fi

# Old app ID; removed after the new entry exists so menus that rescan on the
# first change (noctalia) do not miss it.
rm -f "$data_home/applications/org.macoblox.Launcher.desktop"

# The game window itself (X11 class RobloxPlayer) gets the same icon in docks.
cat > "$data_home/applications/macoblox-roblox-window.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Roblox (Mac O’ Blox)
Exec=$launcher_dir/macoblox-launcher
Icon=macoblox
NoDisplay=true
StartupWMClass=RobloxPlayer
DESKTOP

update-desktop-database "$data_home/applications" 2>/dev/null || true
gtk-update-icon-cache -q -t "$data_home/icons/hicolor" 2>/dev/null || true
echo "Mac O’ Blox installed: find it in the app menu or run: macoblox"
