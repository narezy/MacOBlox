"""Roblox Studio through Wine. No GTK here.

Studio has no macOS-only parts worth keeping, so the Windows version runs
through a portable Wine (Kron4ek's staging wow64 build, which needs no
32-bit system libraries) with DXVK for Direct3D 11. Everything lives in
DATA_DIR/studio: the Wine build, its prefix and Studio itself, downloaded
package by package from Roblox's own deployment like the Windows installer
does."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import core
from .i18n import _

ROOT = core.DATA_DIR / "studio"
WINE = ROOT / "wine"
PREFIX = ROOT / "prefix"
APP = PREFIX / "drive_c" / "Program Files" / "Roblox Studio"
EXECUTABLE = APP / "RobloxStudioBeta.exe"
STATE = ROOT / "state.json"

WINE_RELEASES = "https://github.com/Kron4ek/Wine-Builds"
DXVK_RELEASES = "https://github.com/doitsujin/dxvk"
VERSION_URL = "https://clientsettingscdn.roblox.com/v2/client-version/WindowsStudio64"
PACKAGE_URL = "https://setup.rbxcdn.com/{version}-{name}"

# Where each package is unpacked, relative to the Studio folder. From
# Bloxstrap (MIT), which reads it out of Roblox's own bootstrapper.
PACKAGE_DIRS = {
    "RobloxStudio.zip": "",
    "Libraries.zip": "",
    "LibrariesQt5.zip": "",
    "redist.zip": "",
    "WebView2.zip": "",
    "shaders.zip": "shaders/",
    "ssl.zip": "ssl/",
    "content-avatar.zip": "content/avatar/",
    "content-configs.zip": "content/configs/",
    "content-fonts.zip": "content/fonts/",
    "content-sky.zip": "content/sky/",
    "content-sounds.zip": "content/sounds/",
    "content-textures2.zip": "content/textures/",
    "content-models.zip": "content/models/",
    "content-studio_svg_textures.zip": "content/studio_svg_textures/",
    "content-qt_translations.zip": "content/qt_translations/",
    "content-api-docs.zip": "content/api_docs/",
    "content-textures3.zip": "PlatformContent/pc/textures/",
    "content-terrain.zip": "PlatformContent/pc/terrain/",
    "content-platform-fonts.zip": "PlatformContent/pc/fonts/",
    "content-platform-dictionaries.zip": "PlatformContent/pc/shared_compression_dictionaries/",
    "extracontent-luapackages.zip": "ExtraContent/LuaPackages/",
    "extracontent-translations.zip": "ExtraContent/translations/",
    "extracontent-models.zip": "ExtraContent/models/",
    "extracontent-textures.zip": "ExtraContent/textures/",
    "extracontent-places.zip": "ExtraContent/places/",
    "extracontent-scripts.zip": "ExtraContent/scripts/",
    "studiocontent-models.zip": "StudioContent/models/",
    "studiocontent-textures.zip": "StudioContent/textures/",
    "BuiltInPlugins.zip": "BuiltInPlugins/",
    "BuiltInStandalonePlugins.zip": "BuiltInStandalonePlugins/",
    "ApplicationConfig.zip": "ApplicationConfig/",
    "Plugins.zip": "Plugins/",
    "Qml.zip": "Qml/",
    "StudioFonts.zip": "StudioFonts/",
    "RibbonConfig.zip": "RibbonConfig/",
}
# Installs the Edge WebView2 runtime on Windows; not used under Wine.
SKIPPED_PACKAGES = {"WebView2RuntimeInstaller.zip"}

APP_SETTINGS = """<?xml version="1.0" encoding="UTF-8"?>
<Settings>
\t<ContentFolder>content</ContentFolder>
\t<BaseUrl>http://www.roblox.com</BaseUrl>
</Settings>
"""


def _state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def _save_state(state):
    ROOT.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


def installed_version():
    return _state().get("studio") if EXECUTABLE.exists() else None


def _open(url, timeout=30):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "MacOBlox"}),
                                  timeout=timeout)


def _latest_tag(releases):
    """Newest release tag, from the redirect of /releases/latest (the API
    has a low anonymous rate limit)."""
    with _open(f"{releases}/releases/latest") as response:
        return response.url.rstrip("/").rsplit("/", 1)[1]


def _download(url, target, progress=None, label=""):
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    with _open(url, timeout=60) as response, open(partial, "wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while chunk := response.read(1 << 16):
            out.write(chunk)
            done += len(chunk)
            if progress and total:
                progress(done / total, _("{label}: {done} of {total} MB", label=label,
                                         done=done >> 20, total=total >> 20))
    partial.replace(target)
    return target


def _wine_env():
    env = dict(os.environ)
    env.update({
        "WINEPREFIX": str(PREFIX),
        "WINEDEBUG": "-all",
        # No Mono/Gecko install prompts; DXVK's Direct3D instead of wined3d.
        "WINEDLLOVERRIDES": "mscoree,mshtml=;d3d11,d3d10core,dxgi,d3d9=n,b",
        "DXVK_LOG_LEVEL": "none",
    })
    return env


def _wine(*args, **kwargs):
    return subprocess.run([str(WINE / "bin" / "wine"), *map(str, args)], env=_wine_env(),
                          stdin=subprocess.DEVNULL, **kwargs)


def _ensure_wine(state, progress):
    if state.get("wine") and (WINE / "bin" / "wine").exists():
        return
    tag = _latest_tag(WINE_RELEASES)
    name = f"wine-{tag}-staging-amd64-wow64.tar.xz"
    archive = _download(f"{WINE_RELEASES}/releases/download/{tag}/{name}",
                        core.DOWNLOADS / name, progress, "Wine")
    progress(1, _("Unpacking Wine"))
    shutil.rmtree(WINE, ignore_errors=True)
    WINE.mkdir(parents=True)
    subprocess.run(["tar", "-xJf", str(archive), "-C", str(WINE), "--strip-components=1"], check=True)
    archive.unlink()
    state["wine"] = tag
    _save_state(state)


def _ensure_prefix(state, progress):
    if state.get("prefix") == state.get("wine") and (PREFIX / "system.reg").exists():
        return
    progress(0, _("Preparing Wine"))
    _wine("wineboot", "--init", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    subprocess.run([str(WINE / "bin" / "wineserver"), "--wait"], env=_wine_env())
    state["prefix"] = state["wine"]
    _save_state(state)


def _ensure_dxvk(state, progress):
    if state.get("dxvk"):
        return
    tag = _latest_tag(DXVK_RELEASES)
    name = f"dxvk-{tag.lstrip('v')}.tar.gz"
    archive = _download(f"{DXVK_RELEASES}/releases/download/{tag}/{name}",
                        core.DOWNLOADS / name, progress, "DXVK")
    unpack = core.DOWNLOADS / "dxvk"
    shutil.rmtree(unpack, ignore_errors=True)
    unpack.mkdir(parents=True)
    subprocess.run(["tar", "-xzf", str(archive), "-C", str(unpack), "--strip-components=1"], check=True)
    windows = PREFIX / "drive_c" / "windows"
    for folder, target in (("x64", "system32"), ("x32", "syswow64")):
        if (unpack / folder).is_dir() and (windows / target).is_dir():
            for dll in (unpack / folder).glob("*.dll"):
                shutil.copy2(dll, windows / target / dll.name)
    shutil.rmtree(unpack, ignore_errors=True)
    archive.unlink()
    state["dxvk"] = tag
    _save_state(state)


def latest_version():
    with _open(VERSION_URL, timeout=15) as response:
        return json.load(response)["clientVersionUpload"]


def _manifest(version):
    """[(name, md5, packed size)] from rbxPkgManifest.txt."""
    with _open(PACKAGE_URL.format(version=version, name="rbxPkgManifest.txt")) as response:
        lines = response.read().decode().split()
    if not lines or lines[0] != "v0":
        raise RuntimeError(_("Unknown Studio package manifest format"))
    return [(lines[i], lines[i + 1], int(lines[i + 2])) for i in range(1, len(lines) - 3, 4)]


def _extract(archive, target):
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            name = entry.filename.replace("\\", "/").lstrip("/")
            if not name or name.endswith("/") or ".." in Path(name).parts:
                continue
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(entry) as source, open(path, "wb") as out:
                shutil.copyfileobj(source, out, 1 << 20)


def _install_studio(state, version, progress):
    packages = [p for p in _manifest(version) if p[0] not in SKIPPED_PACKAGES]
    unknown = [name for name, _md5, _size in packages if name not in PACKAGE_DIRS]
    if unknown:
        # A new package: Roblox's bootstrapper knows its folder, we do not yet.
        core.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        (core.CACHE_DIR / "studio-unknown-packages.txt").write_text("\n".join(unknown) + "\n")
    total = sum(size for _name, _md5, size in packages) or 1
    done = 0
    staging = APP.with_name(APP.name + ".new")
    shutil.rmtree(staging, ignore_errors=True)
    folder = core.DOWNLOADS / f"studio-{version}"

    def fetch(package):
        name, md5, _size = package
        archive = folder / name
        for _attempt in range(3):
            _download(PACKAGE_URL.format(version=version, name=name), archive)
            if hashlib.md5(archive.read_bytes()).hexdigest() == md5:
                return package, archive
        raise RuntimeError(_("{name} failed its checksum", name=name))

    with ThreadPoolExecutor(max_workers=4) as pool:
        for (name, _md5, size), archive in pool.map(fetch, packages):
            done += size
            progress(done / total, _("Roblox Studio: {done} of {total} MB",
                                     done=done >> 20, total=total >> 20))
            _extract(archive, staging / PACKAGE_DIRS.get(name, ""))
            archive.unlink()
    (staging / "AppSettings.xml").write_text(APP_SETTINGS)
    shutil.rmtree(folder, ignore_errors=True)
    shutil.rmtree(APP, ignore_errors=True)
    staging.rename(APP)
    state["studio"] = version
    _save_state(state)


def install(progress=lambda fraction, text: None):
    """Installs or updates everything Studio needs. progress(fraction, text)
    gets the fraction of the whole job."""
    state = _state()
    steps = [(0.00, 0.20, lambda p: _ensure_wine(state, p)),
             (0.20, 0.25, lambda p: _ensure_prefix(state, p)),
             (0.25, 0.30, lambda p: _ensure_dxvk(state, p))]
    version = latest_version()
    if version != installed_version():
        steps.append((0.30, 1.00, lambda p: _install_studio(state, version, p)))
    for start, end, step in steps:
        step(lambda fraction, text, s=start, e=end: progress(s + (e - s) * min(fraction, 1), text))
    progress(1, _("Done"))


def needs_install():
    state = _state()
    return not (installed_version() and state.get("wine") and state.get("dxvk"))


def running():
    return any(re.search(r"RobloxStudioBeta\.exe", args) for _pid, args in core._user_processes())


def launch(arguments=()):
    """Starts Studio; arguments are roblox-studio: or roblox-studio-auth:
    links and place files, passed on like the Windows protocol handler."""
    core.LOGS.mkdir(parents=True, exist_ok=True)
    old = sorted(core.LOGS.glob("studio-*.log"), key=lambda path: path.stat().st_mtime)
    for path in old[:-9]:
        path.unlink(missing_ok=True)
    log = open(core.LOGS / time.strftime("studio-%Y%m%d-%H%M%S.log"), "wb")
    process = subprocess.Popen([str(WINE / "bin" / "wine"), str(EXECUTABLE), *arguments],
                               cwd=str(APP), env=_wine_env(), stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    log.close()
    return process
