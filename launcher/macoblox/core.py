"""Backend of the Mac O’ Blox launcher: paths, settings, fast flags, Roblox
updates and running the macOS client through Darling. No GTK here."""

import json
import os
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

from . import __version__
from .i18n import _

PROJECT = Path(__file__).resolve().parents[2]
# Everything the launcher writes: the project folder for a git checkout, the
# user's data folder when the sources are installed read-only (a package).
DATA_DIR = (PROJECT if os.access(PROJECT, os.W_OK) else
            Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "macoblox")
APP_BUNDLE = DATA_DIR / "RobloxPlayer.app"
BUILD_DIR = DATA_DIR / "build"
SHIM = BUILD_DIR / "libMacOBloxShims.dylib"
# Frameworks RobloxPlayer links that Darling lacks; stubs from frameworks/.
FRAMEWORKS = ["CoreML", "CoreHaptics", "DeviceCheck"]
FRAMEWORKS_BUILD = BUILD_DIR / "frameworks"
# Packages install Darling's macOS root to /usr/libexec/darling, a build from
# source to /usr/local/libexec/darling.
DARLING_SYSROOT = next((path for path in (Path("/usr/libexec/darling"), Path("/usr/local/libexec/darling"))
                        if path.is_dir()), Path("/usr/libexec/darling"))
DARLING_PREFIX = Path(os.environ.get("DPREFIX") or Path.home() / ".darling")
NATIVE_LIBS = ["libavcodec", "libavformat", "libavutil", "libswresample"]
NATIVE_BUILD = BUILD_DIR / "native"
BUILD_SCRIPT = PROJECT / "build_debug_shim.sh"
LOGS = DATA_DIR / "logs"
BACKUPS = DATA_DIR / "backups"
DOWNLOADS = DATA_DIR / "downloads"
ICONS = PROJECT / "branding" / "icons"
FAST_FLAGS = APP_BUNDLE / "Contents" / "MacOS" / "ClientSettings" / "ClientAppSettings.json"

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "macoblox"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "macoblox"
SETTINGS_FILE = CONFIG_DIR / "settings.json"

DARLING_HOME = DARLING_PREFIX / "Users" / os.environ.get("USER", "user")
SESSION_FILES = [
    DARLING_HOME / "Library" / "MacOBlox" / "Cookies.plist",
    DARLING_HOME / "Library" / "MacOBlox" / "Keychain",
]

VERSION_URL = "https://clientsettingscdn.roblox.com/v2/client-version/MacPlayer"
DOWNLOAD_URL = "https://setup.rbxcdn.com/mac/{upload}-RobloxPlayer.zip"

DEFAULT_SETTINGS = {
    "language": "en",
    "mouse_sensitivity": 1.0,
    "hide_menu_bar": False,
    "dns": "system",
    "dns_custom": "",
    "show_launcher_after_exit": True,
    "diagnostic_signals": False,
    "trace_udp": False,
    "trace_lock": False,
    "trace_events": False,
    "trace_gl": False,
    "keep_logs": 30,
}

# Settings -> environment variables understood by the shim.
TRACE_ENV = {
    "diagnostic_signals": "MACOBLOX_DIAGNOSTIC_SIGNALS",
    "trace_udp": "MACOBLOX_TRACE_UDP",
    "trace_lock": "MACOBLOX_TRACE_LOCK",
    "trace_events": "MACOBLOX_TRACE_EVENTS",
    "trace_gl": "MACOBLOX_TRACE_GL",
}


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    try:
        settings.update(json.loads(SETTINGS_FILE.read_text()))
    except (OSError, ValueError):
        pass
    return settings


def save_settings(settings):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps(settings, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------- fast flags

def load_fast_flags():
    try:
        data = json.loads(FAST_FLAGS.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_fast_flags(flags):
    FAST_FLAGS.parent.mkdir(parents=True, exist_ok=True)
    FAST_FLAGS.write_text(json.dumps(flags, indent=2, ensure_ascii=False))


def parse_flag_value(text):
    """Turn what the user typed into the JSON value Roblox expects."""
    stripped = text.strip()
    lowered = stripped.lower()
    if lowered in ("true", "false"):
        return lowered == "true"
    try:
        return int(stripped)
    except ValueError:
        return stripped


def format_flag_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


# ------------------------------------------------------------------ versions

def installed_version():
    try:
        with open(APP_BUNDLE / "Contents" / "Info.plist", "rb") as file:
            return plistlib.load(file).get("CFBundleShortVersionString")
    except (OSError, plistlib.InvalidFileException):
        return None


def latest_version():
    """Returns (version, clientVersionUpload) from Roblox's version service."""
    request = urllib.request.Request(VERSION_URL, headers={"User-Agent": "MacOBlox"})
    with urllib.request.urlopen(request, timeout=15) as response:
        data = json.load(response)
    return data["version"], data["clientVersionUpload"]


def update_roblox(upload, progress=None):
    """Download the official macOS client and swap it in, keeping fast flags.
    The previous bundle is moved to backups/. progress(fraction, text)."""
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    archive = DOWNLOADS / f"{upload}-RobloxPlayer.zip"
    request = urllib.request.Request(DOWNLOAD_URL.format(upload=upload),
                                     headers={"User-Agent": "MacOBlox"})
    with urllib.request.urlopen(request, timeout=30) as response, open(archive, "wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while chunk := response.read(1 << 16):
            out.write(chunk)
            done += len(chunk)
            if progress and total:
                progress(done / total * 0.9, _("Downloading {done} of {total} MB",
                                                  done=done >> 20, total=total >> 20))
    if not zipfile.is_zipfile(archive):
        raise RuntimeError(_("The download is not a zip archive"))
    if progress:
        progress(0.92, _("Unpacking"))
    unpack = Path(tempfile.mkdtemp(prefix="unpack-", dir=DOWNLOADS))
    # unzip keeps the executable bits, zipfile does not.
    subprocess.run(["unzip", "-q", str(archive), "-d", str(unpack)], check=True)
    new_bundle = unpack / "RobloxPlayer.app"
    if not new_bundle.is_dir():
        raise RuntimeError(_("The archive has no RobloxPlayer.app"))
    flags = load_fast_flags()
    old_version = installed_version() or "unknown"
    BACKUPS.mkdir(parents=True, exist_ok=True)
    backup = BACKUPS / f"RobloxPlayer-{old_version}.app"
    if backup.exists():
        shutil.rmtree(backup)
    if APP_BUNDLE.exists():
        APP_BUNDLE.rename(backup)
    new_bundle.rename(APP_BUNDLE)
    shutil.rmtree(unpack, ignore_errors=True)
    if flags:
        save_fast_flags(flags)
    if progress:
        progress(1.0, _("Done"))
    return backup


# ----------------------------------------------------------------- processes

def _user_processes():
    uid = os.getuid()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            args = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        yield int(entry.name), args


def roblox_pids():
    """Host PIDs of running RobloxPlayer / RobloxCrashHandler processes."""
    pids = []
    for pid, args in _user_processes():
        if args.startswith("darling shell"):
            continue
        if "RobloxPlayer" in args.split(" ", 1)[0] or "RobloxCrashHandler" in args:
            pids.append(pid)
    return pids


def _darlingservers():
    """darlingserver processes of our prefix."""
    return [pid for pid, args in _user_processes()
            if args.startswith(f"darlingserver {DARLING_PREFIX} ")]


def darlingserver_running():
    return bool(_darlingservers())


def stop_roblox():
    pids = roblox_pids()
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + 3
    while time.time() < deadline and roblox_pids():
        time.sleep(0.2)
    for pid in roblox_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def _darling_path(path):
    """Path of a file under the Darling prefix as seen inside the container."""
    return "/" + str(path.relative_to(DARLING_PREFIX))


def logout():
    # Files inside ~/.darling must not be removed from the host while
    # darlingserver runs: its overlay then stops showing new files to the host.
    if darlingserver_running():
        subprocess.run(["darling", "shell", "/bin/rm", "-rf",
                        *[_darling_path(path) for path in SESSION_FILES]],
                       env=dict(os.environ, EGL_PLATFORM="x11"), stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        return
    for path in SESSION_FILES:
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        elif path.exists():
            path.unlink()


def cleanup_logs(keep):
    """Remove old logs written by the launcher itself (launch-YYYYmmdd-HHMMSS.log);
    logs from run_debug.sh and other tools are left alone."""
    import re
    pattern = re.compile(r"launch-\d{8}-\d{6}\.log")
    logs = sorted((p for p in LOGS.glob("launch-*.log") if pattern.fullmatch(p.name)),
                  key=lambda p: p.stat().st_mtime, reverse=True)
    for old in logs[keep:]:
        try:
            old.unlink()
        except OSError:
            pass


def build_shim():
    result = subprocess.run([str(BUILD_SCRIPT)], capture_output=True, text=True,
                            env=dict(os.environ, MACOBLOX_BUILD_DIR=str(BUILD_DIR),
                                     DARLING_SYSROOT=str(DARLING_SYSROOT)))
    return result.returncode == 0, (result.stdout + result.stderr).strip()


def shim_built():
    return SHIM.exists() and all((FRAMEWORKS_BUILD / f"{name}.framework" / name).exists()
                                 for name in FRAMEWORKS)


def missing_tools():
    """Programs the launcher needs that are not installed."""
    needed = {"darling": "darling", "clang": "clang", "ld.lld": "lld", "unzip": "unzip"}
    missing = [package for program, package in needed.items() if not shutil.which(program)]
    if not DARLING_SYSROOT.is_dir() and "darling" not in missing:
        missing.append(f"darling ({DARLING_SYSROOT})")
    return missing


def _missing_frameworks():
    relative = Path("System/Library/Frameworks")
    return [name for name in FRAMEWORKS
            if not (DARLING_PREFIX / relative / f"{name}.framework").exists()
            and not (DARLING_SYSROOT / relative / f"{name}.framework").exists()]


def prepare_prefix(env):
    """Puts the stub frameworks and the patched ffmpeg bridges into the
    Darling prefix. Its system folders belong to root, so programs inside
    Darling cannot write there; the files go straight into the prefix's
    upper layer (~/.darling) while Darling is stopped, then Darling sees them
    on its next start."""
    frameworks = _missing_frameworks()
    bridges = _patched_ffmpeg_bridges()
    if not frameworks and not bridges:
        return
    if not DARLING_PREFIX.is_dir():
        # Let Darling create the prefix first.
        subprocess.run(["darling", "shell", "/bin/true"], env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    if darlingserver_running():
        restart_darling()
    target = DARLING_PREFIX / "System" / "Library" / "Frameworks"
    target.mkdir(parents=True, exist_ok=True)
    for name in frameworks:
        shutil.copytree(FRAMEWORKS_BUILD / f"{name}.framework", target / f"{name}.framework",
                        symlinks=True, dirs_exist_ok=True)
    target = DARLING_PREFIX / "usr" / "lib" / "native"
    target.mkdir(parents=True, exist_ok=True)
    for path in bridges:
        shutil.copy2(path, target / path.name)


def _initializer_offset(data):
    """File offset of the `_initializer` function in the x86_64 slice of a
    (fat) Mach-O library, or None."""
    slice_offset = 0
    if data[:4] == b"\xca\xfe\xba\xbe":
        for index in range(struct.unpack_from(">I", data, 4)[0]):
            cputype, _sub, offset, _size, _align = struct.unpack_from(">5I", data, 8 + index * 20)
            if cputype == 0x01000007:
                slice_offset = offset
                break
        else:
            return None
    if data[slice_offset:slice_offset + 4] != b"\xcf\xfa\xed\xfe":
        return None
    ncmds = struct.unpack_from("<I", data, slice_offset + 16)[0]
    position = slice_offset + 32
    segments, symtab = [], None
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, position)
        if command == 0x19:  # LC_SEGMENT_64
            segments.append(struct.unpack_from("<4Q", data, position + 24))
        elif command == 0x2:  # LC_SYMTAB
            symtab = struct.unpack_from("<4I", data, position + 8)
        position += size
    if not symtab:
        return None
    symoff, nsyms, stroff, _strsize = symtab
    for index in range(nsyms):
        strx, _type, _sect, _desc, value = struct.unpack_from("<IBBHQ", data, slice_offset + symoff + index * 16)
        name_start = slice_offset + stroff + strx
        if data[name_start:data.index(b"\0", name_start)] != b"_initializer":
            continue
        for vmaddr, vmsize, fileoff, _filesize in segments:
            if vmaddr <= value < vmaddr + vmsize:
                return slice_offset + fileoff + value - vmaddr
    return None


def _host_libraries():
    try:
        output = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True).stdout
    except OSError:
        return set()
    return {line.split()[0] for line in output.splitlines()[1:] if line.strip()}


def _patched_ffmpeg_bridges():
    """Darling's ffmpeg bridges (/usr/lib/native/libav*.dylib) load one exact
    host ffmpeg version from an initializer and the game exits when it is
    missing ("Cannot load libavformat.so.60"). Roblox does not need ffmpeg,
    so when the host has another version, the prefix gets copies whose
    initializer returns right away. Returns the patched files to install."""
    host = None
    patched = []
    for name in NATIVE_LIBS:
        if (DARLING_PREFIX / "usr/lib/native" / f"{name}.dylib").exists():
            continue
        stock = DARLING_SYSROOT / "usr/lib/native" / f"{name}.dylib"
        try:
            data = bytearray(stock.read_bytes())
        except OSError:
            continue
        wanted = re.search(rb"%s\.so\.\d+" % name.encode(), data)
        host = _host_libraries() if host is None else host
        if not wanted or wanted.group().decode() in host:
            continue
        offset = _initializer_offset(data)
        if offset is None or data[offset] != 0x55:  # push %rbp
            continue
        data[offset] = 0xC3  # ret
        NATIVE_BUILD.mkdir(parents=True, exist_ok=True)
        (NATIVE_BUILD / stock.name).write_bytes(data)
        (NATIVE_BUILD / stock.name).chmod(0o755)
        patched.append(NATIVE_BUILD / stock.name)
    return patched


def _process_state(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return None


def clear_stale_darling():
    """If the container's init is gone or a zombie (its parent never reaped
    it), darling refuses to start ("Cannot open mnt namespace file"); move
    its pid file and socket aside so a new server starts."""
    prefix = DARLING_PREFIX
    try:
        pid = int((prefix / ".init.pid").read_text().strip())
    except (OSError, ValueError):
        return
    if _process_state(pid) not in (None, "Z"):
        return
    for name in (".init.pid", ".darlingserver.sock"):
        path = prefix / name
        if path.exists():
            path.rename(prefix / (name + ".stale"))


def restart_darling():
    """Stops the prefix's darlingserver and its launchd, which otherwise
    stays behind as an orphan; the next darling command starts them again."""
    try:
        init = int((DARLING_PREFIX / ".init.pid").read_text().strip())
    except (OSError, ValueError):
        init = None
    for pid in _darlingservers():
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    time.sleep(2)
    if init and _process_state(init) not in (None, "Z"):
        try:
            os.kill(init, signal.SIGTERM)
        except OSError:
            pass
        time.sleep(1)
    clear_stale_darling()


def icon_argb_file():
    """Write the logo in _NET_WM_ICON layout for the shim (see MACOBLOX_ICON_ARGB)."""
    target = CACHE_DIR / "icon.argb"
    sources = [ICONS / f"macoblox-{size}.png" for size in (32, 64, 128)]
    if target.exists() and all(target.stat().st_mtime >= s.stat().st_mtime for s in sources if s.exists()):
        return target
    from gi.repository import GdkPixbuf  # only needed here

    words = bytearray()
    for source in sources:
        if not source.exists():
            continue
        pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(source))
        if not pixbuf.get_has_alpha():
            pixbuf = pixbuf.add_alpha(False, 0, 0, 0)
        width, height, stride = pixbuf.get_width(), pixbuf.get_height(), pixbuf.get_rowstride()
        pixels = pixbuf.get_pixels()
        words += struct.pack("<II", width, height)
        for y in range(height):
            row = pixels[y * stride:y * stride + width * 4]
            for x in range(0, width * 4, 4):
                r, g, b, a = row[x], row[x + 1], row[x + 2], row[x + 3]
                words += struct.pack("<I", (a << 24) | (r << 16) | (g << 8) | b)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    target.write_bytes(bytes(words))
    return target


LAUNCH_SCRIPT = r'''
project=$1 shim_dir=$2; shift 2
for kv in "$@"; do export "$kv"; done
app="$project/RobloxPlayer.app/Contents/MacOS"
cd "$app" || exit 1
# Nothing may run between these exports and exec: every program started
# after them would get the shim injected too.
export DYLD_FORCE_FLAT_NAMESPACE=1
export DYLD_INSERT_LIBRARIES="$shim_dir/libMacOBloxShims.dylib"
export DYLD_LIBRARY_PATH="$shim_dir:$app"
exec ./RobloxPlayer
'''


def host_vram_bytes():
    """Largest dedicated VRAM among the host GPUs (amdgpu exposes it in sysfs)."""
    best = 0
    for path in Path("/sys/class/drm").glob("card*/device/mem_info_vram_total"):
        try:
            best = max(best, int(path.read_text().strip()))
        except (OSError, ValueError):
            pass
    return best


class HostAudio:
    """Game sound played on the host. The shim writes raw float32 stereo
    44.1 kHz audio into a FIFO and pw-cat plays it through PipeWire. Darling's
    own audio (CoreAudio over PulseAudio on GCD) overflows Darling's
    workqueue thread stacks within seconds, so it is not used. The launcher
    keeps the FIFO open read/write for the whole session, so pw-cat never
    sees end of file and the game can reopen it any time."""

    def __init__(self, fifo, keep, player):
        self.fifo, self.keep, self.player = fifo, keep, player

    @classmethod
    def start(cls):
        if not shutil.which("pw-cat"):
            return None
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        fifo = CACHE_DIR / f"audio-{os.getpid()}.fifo"
        if fifo.exists():
            fifo.unlink()
        os.mkfifo(fifo, 0o600)
        keep = os.open(fifo, os.O_RDWR)
        player = subprocess.Popen(
            ["pw-cat", "--playback", "--raw", "--format", "f32", "--rate", "44100",
             "--channels", "2", "--latency", "40ms", "--media-role", "Game",
             "-P", '{ application.name = "Roblox" application.icon-name = "macoblox" '
                   'media.name = "Roblox (Mac O’ Blox)" }',
             str(fifo)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return cls(fifo, keep, player)

    def stop(self):
        self.player.terminate()
        try:
            self.player.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.player.kill()
        os.close(self.keep)
        try:
            self.fifo.unlink()
        except OSError:
            pass


class RobloxSession:
    """One run of the client. poll() returns None while it is running."""

    def __init__(self, settings):
        self.settings = settings
        self.log_path = None
        self.process = None
        self.seen_roblox = False
        self.gone_since = None
        self.dns = None
        self.audio = None

    def environment(self):
        env = dict(os.environ)
        # Darling's Mesa receives X11 displays; a Wayland session may say otherwise.
        env["EGL_PLATFORM"] = "x11"
        return env

    def shim_variables(self):
        variables = [f"MACOBLOX_MOUSE_SENSITIVITY={self.settings['mouse_sensitivity']:.2f}"]
        vram = host_vram_bytes()
        if vram:
            variables.append(f"MACOBLOX_VRAM_BYTES={vram}")
        if self.settings.get("hide_menu_bar"):
            variables.append("MACOBLOX_HIDE_MENU_BAR=1")
        if self.dns:
            variables.append(f"MACOBLOX_DNS={self.dns.address}")
        if self.audio:
            variables.append(f"MACOBLOX_AUDIO_FIFO=/Volumes/SystemRoot{self.audio.fifo}")
        else:
            # Darling's own audio path crashes the game (see HostAudio).
            variables.append("MACOBLOX_AUDIO=0")
        for key, name in TRACE_ENV.items():
            if self.settings.get(key):
                variables.append(f"{name}=1")
        try:
            variables.append(f"MACOBLOX_ICON_ARGB=/Volumes/SystemRoot{icon_argb_file()}")
        except Exception:
            pass
        return variables

    def start(self):
        missing = missing_tools()
        if missing:
            raise RuntimeError(_("Install these first: {programs}", programs=", ".join(missing)))
        if not shim_built():
            ok, output = build_shim()
            if not ok:
                raise RuntimeError(_("Could not build the shim:\n{output}", output=output))
        env = self.environment()
        prepare_prefix(env)
        provider = self.settings.get("dns", "system")
        if provider != "system" and (provider != "custom" or self.settings.get("dns_custom")):
            from .dns import DnsForwarder
            self.dns = DnsForwarder(provider, self.settings.get("dns_custom", ""))
        self.audio = HostAudio.start()
        clear_stale_darling()
        if not darlingserver_running():
            # The first process after darlingserver starts sometimes fails to
            # check in; warm the server up with a trivial command first.
            subprocess.run(["darling", "shell", "/bin/true"], env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        LOGS.mkdir(parents=True, exist_ok=True)
        cleanup_logs(int(self.settings.get("keep_logs", 30)) - 1)
        self.log_path = LOGS / time.strftime("launch-%Y%m%d-%H%M%S.log")
        log = open(self.log_path, "wb")
        log.write(f"Mac O’ Blox {__version__}\n".encode())
        log.flush()
        command = ["darling", "shell", "/bin/bash", "-c", LAUNCH_SCRIPT, "macoblox",
                   f"/Volumes/SystemRoot{DATA_DIR}", f"/Volumes/SystemRoot{SHIM.parent}",
                   *self.shim_variables()]
        self.process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                        stdout=log, stderr=subprocess.STDOUT,
                                        start_new_session=True)
        log.close()

    def poll(self):
        """None while running, otherwise the exit status (or -1 if unknown)."""
        status = self.process.poll() if self.process else -1
        if status is not None:
            self.finish()
            return status
        # darling shell can outlive a Roblox that was killed; watch the game
        # processes themselves as well.
        if roblox_pids():
            self.seen_roblox = True
            self.gone_since = None
        elif self.seen_roblox:
            self.gone_since = self.gone_since or time.time()
            if time.time() - self.gone_since > 6:
                self.finish()
                return -1
        return None

    def finish(self):
        if self.dns:
            self.dns.stop()
            self.dns = None
        if self.audio:
            self.audio.stop()
            self.audio = None
