"""Author card, community and donation links for the Info page. No GTK here."""

import http.client
import json
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

from . import core, dns

NAME = "Narezany"
ROBLOX_USER = "H4Ru_456"
ROBLOX_ID = 8847914296
PROFILE_URL = f"https://www.roblox.com/users/{ROBLOX_ID}/profile"
DISCORD_URL = "https://discord.gg/bpX9rTttCa"
GITHUB_URL = "https://github.com/narezy/MacOBlox"
BOOSTY_URL = "https://boosty.to/ega_link"
YOOMONEY_URL = "https://yoomoney.ru/to/4100118196133693"

AVATAR = core.CACHE_DIR / "author-avatar.png"
THUMBNAIL_API = ("https://thumbnails.roblox.com/v1/users/avatar-headshot"
                 f"?userIds={ROBLOX_ID}&size=150x150&format=Png&isCircular=false")


class _PinnedHTTPS(http.client.HTTPSConnection):
    """HTTPS to a known IP while still checking the certificate for `host`."""

    def __init__(self, host, address, timeout):
        super().__init__(host, timeout=timeout)
        self.address = address

    def connect(self):
        raw = socket.create_connection((self.address, 443), self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def _get(url, provider, timeout=10):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read()
    except urllib.error.URLError as error:
        # Roblox image hosts often do not resolve through ISP resolvers
        # (the same reason the game has its own DNS setting).
        if not isinstance(error.reason, socket.gaierror):
            raise
    parts = urllib.parse.urlsplit(url)
    for address in dns.resolve_a(parts.hostname, provider):
        connection = _PinnedHTTPS(parts.hostname, address, timeout)
        try:
            path = parts.path + ("?" + parts.query if parts.query else "")
            connection.request("GET", path, headers={"User-Agent": "MacOBlox"})
            response = connection.getresponse()
            if response.status == 200:
                return response.read()
        except OSError:
            continue
        finally:
            connection.close()
    raise OSError(f"could not download {url}")


def avatar(settings, max_age=86400):
    """Path to the cached avatar headshot, refreshed once a day. Returns the
    old copy (or None) when Roblox is unreachable."""
    try:
        if time.time() - AVATAR.stat().st_mtime < max_age:
            return AVATAR
    except OSError:
        pass
    provider = settings.get("dns")
    provider = provider if provider in dns.PROVIDERS else "quad9"
    try:
        info = json.loads(_get(THUMBNAIL_API, provider))
        image = _get(info["data"][0]["imageUrl"], provider)
        if not image.startswith(b"\x89PNG"):
            raise ValueError("not a PNG")
        core.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        partial = AVATAR.with_suffix(".part")
        partial.write_bytes(image)
        partial.replace(AVATAR)
    except (OSError, ValueError, KeyError, IndexError):
        pass
    return AVATAR if AVATAR.exists() else None
