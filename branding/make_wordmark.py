#!/usr/bin/env python3
"""Builds wordmark-light.png / wordmark-dark.png: the square logo on the left
and "Mac O’ Blox" in Comfortaa Bold (source/, SIL OFL). Needs rsvg-convert
and ImageMagick; the font is used from source/ without installing it."""

import base64
import os
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
THEMES = {"light": "#1f2328", "dark": "#f0f6fc"}  # text colours for GitHub themes

logo = base64.b64encode((HERE / "logo_1024.png").read_bytes()).decode()
with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    (temp / "fonts.conf").write_text(
        '<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>'
        f'<dir>{HERE / "source"}</dir><include ignore_missing="yes">/etc/fonts/fonts.conf</include>'
        f'<cachedir>{temp / "cache"}</cachedir></fontconfig>')
    env = dict(os.environ, FONTCONFIG_FILE=str(temp / "fonts.conf"))
    for theme, color in THEMES.items():
        svg = temp / f"{theme}.svg"
        svg.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="600">'
            f'<image x="40" y="40" width="520" height="520" href="data:image/png;base64,{logo}"/>'
            '<text x="620" y="385" font-family="Comfortaa" font-weight="700" font-size="250" '
            f'fill="{color}">Mac O’ Blox</text></svg>')
        subprocess.run(["rsvg-convert", svg, "-o", temp / f"{theme}.png"], check=True, env=env)
        subprocess.run(["magick", temp / f"{theme}.png", "-trim", "+repage", "-bordercolor", "none",
                        "-border", "24", "-resize", "1200x", HERE / f"wordmark-{theme}.png"], check=True)
