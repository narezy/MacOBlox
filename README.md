<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/wordmark-dark.png">
    <img src="branding/wordmark-light.png" alt="Mac O’ Blox" width="520">
  </picture>
</p>

<p align="center">
  The real macOS Roblox client, running on Linux through <a href="https://www.darlinghq.org">Darling</a>.
</p>

<p align="center">
  <a href="https://discord.gg/bpX9rTttCa"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
  <a href="https://boosty.to/ega_link"><img src="https://img.shields.io/badge/Boosty-support-F15F2C?logo=boosty&logoColor=white" alt="Boosty"></a>
  <a href="https://yoomoney.ru/to/4100118196133693"><img src="https://img.shields.io/badge/%D0%AEMoney-support-8B3FFD" alt="YooMoney"></a>
</p>

<br>

Full graphics with antialiasing, sound, camera and mouse lock, a session that
survives restarts, and a small launcher with fast flags. Roblox Studio too, in
its Windows version through Wine. English and Russian.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/narezy/MacOBlox/main/install.sh | bash
```

It installs Darling and everything else, then puts **Mac O’ Blox** in the app
menu. Open it, press **Install Roblox**, then **Play**. Run the same command
again to update.

Works on Arch and its relatives (CachyOS, EndeavourOS, Manjaro), Ubuntu 24.04+,
Debian 13, Linux Mint 22 and Fedora with Darling built from source.

<details>
<summary>Install by hand</summary>

**1. Darling and the tools**

Arch, CachyOS, EndeavourOS, Manjaro:

```bash
paru -S darling-bin
sudo pacman -S clang lld unzip pipewire-audio python-gobject gtk4 libadwaita
```

Debian, Ubuntu, Mint: download `debs_*.zip` from the
[Darling releases](https://github.com/darlinghq/darling/releases), then:

```bash
unzip debs_*.zip -d darling-debs
sudo apt install ./darling-debs/*/*.deb
sudo apt install clang lld unzip pipewire-bin python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
```

Fedora and others: build Darling with the
[official guide](https://docs.darlinghq.org/build-instructions.html), then:

```bash
sudo dnf install clang lld unzip pipewire-utils python3-gobject gtk4 libadwaita
```

**2. Mac O’ Blox**

```bash
git clone https://github.com/narezy/MacOBlox ~/.local/share/MacOBlox
~/.local/share/MacOBlox/launcher/install.sh
```
</details>

## Questions

<details>
<summary>Is my account safe?</summary>

You sign in inside Roblox itself, the launcher never sees your password. The
session is stored only on your computer, in
`~/.darling/Users/$USER/Library/MacOBlox`. Do not share that folder, it works
like a password. **Sign out** in the settings deletes it.

Mac O’ Blox is not made by Roblox, using it is at your own risk.
</details>

<details>
<summary>Something does not work</summary>

When Roblox does not start, the launcher shows the error with a **Copy**
button. Send it to the [Discord](https://discord.gg/bpX9rTttCa). The last
error is also saved in `~/.cache/macoblox/last-error.txt`.
</details>

<details>
<summary>How do I sign in?</summary>

Create the account on [roblox.com](https://www.roblox.com) first: sign up inside
the game shows a captcha that does not work here. Then sign in in Mac O’ Blox
however you like, with a password or with Quick Login.
</details>

<details>
<summary>Images or servers do not load</summary>

Some providers break Roblox's addresses. In **Settings → DNS for Roblox** pick
Quad9 or Cloudflare. Only Roblox uses it, the rest of the system keeps its DNS.
</details>

<details>
<summary>Roblox Studio</summary>

Press **Roblox Studio** in the launcher. The first time it downloads Wine, DXVK
and Studio (about 800 MB) into its own folder, nothing is installed system-wide.
To sign in, Studio opens the Roblox login in your browser; when the browser asks
how to open the `roblox-studio-auth` link, choose **Roblox Studio (Mac O’ Blox)**.
</details>

<details>
<summary>Flatpak (testing)</summary>

The Flatpak brings Darling along and runs it without root (see
[flatpak/darling-noroot.c](flatpak/darling-noroot.c)), so nothing has to be
installed on the system. Download `MacOBlox-*.flatpak` from the
[latest release](https://github.com/narezy/MacOBlox/releases/latest), then:

```bash
flatpak install --user MacOBlox-0.13-x86_64.flatpak
```

It keeps its own Darling prefix, so sign in to Roblox again there. Roblox Studio
is not in the Flatpak yet. To build it yourself:

```bash
flatpak install --user flathub org.flatpak.Builder org.gnome.Sdk//50 org.freedesktop.Sdk.Extension.llvm22//25.08
cd MacOBlox/flatpak
flatpak run --env=FLATPAK_USER_DIR=$HOME/.local/share/flatpak --command=flatpak-builder org.flatpak.Builder --user --install --force-clean build-dir xyz.narez.MacOBlox.yml
```
</details>

<details>
<summary>How does it work?</summary>

Darling runs macOS programs on Linux. Roblox needs a few things Darling does not
have yet, so Mac O’ Blox adds a small library to the game: it connects the mouse,
sound, OpenGL and network to Linux and fixes bugs along the way. Details are in
[docs/NOTES.md](docs/NOTES.md).
</details>

## Credits

[Darling](https://www.darlinghq.org) · Tux by Larry Ewing and The GIMP ·
[Comfortaa](https://github.com/alexeiva/comfortaa) font (SIL OFL) ·
icons from [Simple Icons](https://simpleicons.org)

Mac O’ Blox is MIT licensed. Not affiliated with Roblox Corporation.
