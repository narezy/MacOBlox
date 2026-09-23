"""GTK 4 / libadwaita interface of the Mac O’ Blox launcher."""

import json
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from . import author, core, i18n  # noqa: E402
from .i18n import _  # noqa: E402

APP_ID = "xyz.narez.MacOBlox"

# Common fast flags. Roblox only honours flags on its client allowlist, so
# some of these may have no effect in a given client version.
PRESETS = [
    {"title": "FPS limit", "subtitle": "DFIntTaskSchedulerTargetFps",
     "flag": "DFIntTaskSchedulerTargetFps", "kind": "number", "default": 144, "min": 30, "max": 1000},
    {"title": "Graphics quality", "subtitle": "DFIntDebugFRMQualityLevelOverride, 1–21",
     "flag": "DFIntDebugFRMQualityLevelOverride", "kind": "number", "default": 10, "min": 1, "max": 21},
    {"title": "MSAA", "subtitle": "FIntDebugForceMSAASamples: 0, 1, 2, 4, 8",
     "flag": "FIntDebugForceMSAASamples", "kind": "number", "default": 4, "min": 0, "max": 8},
    {"title": "No shadows", "subtitle": "FIntRenderShadowIntensity = 0",
     "flag": "FIntRenderShadowIntensity", "kind": "fixed", "value": 0},
    {"title": "No grass", "subtitle": "FIntFRMMinGrassDistance / FIntFRMMaxGrassDistance = 0",
     "flag": ["FIntFRMMinGrassDistance", "FIntFRMMaxGrassDistance"], "kind": "fixed", "value": 0},
]

DNS_CHOICES = [
    ("system", "System (Darling default)"),
    ("quad9", "Quad9 (9.9.9.9, encrypted)"),
    ("cloudflare", "Cloudflare (1.1.1.1, encrypted)"),
    ("google", "Google (8.8.8.8, encrypted)"),
    ("custom", "Custom"),
]


def _toast(overlay, text):
    overlay.add_toast(Adw.Toast.new(text))


class PlayPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        status = Adw.StatusPage()
        status.set_icon_name("macoblox")
        status.set_title("Mac O’ Blox")
        status.set_vexpand(True)
        self.status = status

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                      halign=Gtk.Align.CENTER)
        self.play = Gtk.Button(label=_("Play"))
        self.play.add_css_class("suggested-action")
        self.play.add_css_class("pill")
        self.play.set_size_request(220, 52)
        self.play.connect("clicked", lambda *_args: window.play_clicked())
        box.append(self.play)

        self.stop = Gtk.Button(label=_("Stop Roblox"))
        self.stop.add_css_class("destructive-action")
        self.stop.add_css_class("pill")
        self.stop.set_visible(False)
        self.stop.connect("clicked", lambda *_args: window.stop())
        box.append(self.stop)

        self.log_button = Gtk.Button(label=_("Open last log"))
        self.log_button.add_css_class("flat")
        self.log_button.set_visible(False)
        self.log_button.connect("clicked", lambda *_args: window.open_last_log())
        box.append(self.log_button)

        links = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER, margin_top=18)
        for title, icon, uri in _links():
            button = Gtk.Button(icon_name=icon, tooltip_text=title)
            button.add_css_class("flat")
            button.add_css_class("circular")
            button.connect("clicked", lambda *_args, u=uri: _open_uri(window, u))
            links.append(button)
        box.append(links)

        status.set_child(box)
        self.append(status)
        self.refresh(running=window.session is not None)

    def refresh(self, running=False):
        version = core.installed_version()
        parts = [_("Roblox {version}", version=version) if version else _("Roblox not found")]
        parts.append(_("Darling running") if core.darlingserver_running()
                     else _("Darling starts with the game"))
        self.status.set_description(" · ".join(parts))
        self.play.set_sensitive(not running)
        if running:
            self.play.set_label(_("Roblox is running"))
        else:
            self.play.set_label(_("Play") if version else _("Install Roblox"))
        self.stop.set_visible(running)
        self.log_button.set_visible(self.window.last_log is not None and not running)


class FlagsPage(Adw.PreferencesPage):
    def __init__(self, window):
        super().__init__(title=_("Fast flags"), icon_name="preferences-other-symbolic")
        self.window = window
        self.flags = core.load_fast_flags()
        self.preset_flags = set()

        presets = Adw.PreferencesGroup(
            title=_("Popular"),
            description=_("Roblox only applies flags from its allowlist, some flags may have no effect."))
        for preset in PRESETS:
            presets.add(self._preset_row(preset))
        self.add(presets)

        self.custom = Adw.PreferencesGroup(title=_("Custom flags"))
        add_button = Gtk.Button(icon_name="list-add-symbolic", valign=Gtk.Align.CENTER)
        add_button.add_css_class("flat")
        add_button.set_tooltip_text(_("Add flag"))
        add_button.connect("clicked", lambda *_args: self._add_custom_row("", ""))
        import_button = Gtk.Button(label=_("Import JSON"), valign=Gtk.Align.CENTER)
        import_button.add_css_class("flat")
        import_button.connect("clicked", lambda *_args: self._import_dialog())
        suffix = Gtk.Box(spacing=6)
        suffix.append(import_button)
        suffix.append(add_button)
        self.custom.set_header_suffix(suffix)
        self.add(self.custom)
        self.custom_rows = []
        for name, value in self.flags.items():
            if name not in self.preset_flags:
                self._add_custom_row(name, core.format_flag_value(value))

        file_group = Adw.PreferencesGroup()
        path_row = Adw.ActionRow(title=_("File"), subtitle=str(core.FAST_FLAGS))
        path_row.set_subtitle_selectable(True)
        file_group.add(path_row)
        self.add(file_group)

    # -- presets
    def _preset_row(self, preset):
        names = preset["flag"] if isinstance(preset["flag"], list) else [preset["flag"]]
        self.preset_flags.update(names)
        enabled = all(name in self.flags for name in names)
        if preset["kind"] == "number":
            row = Adw.SpinRow.new_with_range(preset["min"], preset["max"], 1)
            row.set_title(_(preset["title"]))
            row.set_subtitle(preset["subtitle"])
            current = self.flags.get(names[0], preset["default"])
            row.set_value(float(current) if str(current).lstrip("-").isdigit() else preset["default"])
            switch = Gtk.Switch(active=enabled, valign=Gtk.Align.CENTER)
            row.add_suffix(switch)

            def apply(*_args):
                for name in names:
                    if switch.get_active():
                        self.flags[name] = int(row.get_value())
                    else:
                        self.flags.pop(name, None)
                self._save()

            switch.connect("notify::active", apply)
            row.connect("notify::value", lambda *_args: switch.get_active() and apply())
            return row
        row = Adw.SwitchRow(title=_(preset["title"]), subtitle=preset["subtitle"], active=enabled)

        def toggle(*_args):
            for name in names:
                if row.get_active():
                    self.flags[name] = preset["value"]
                else:
                    self.flags.pop(name, None)
            self._save()

        row.connect("notify::active", toggle)
        return row

    # -- custom flags
    def _add_custom_row(self, name, value):
        row = Adw.ExpanderRow(title=name or _("New flag"), subtitle=value)
        name_row = Adw.EntryRow(title=_("Name"))
        name_row.set_text(name)
        value_row = Adw.EntryRow(title=_("Value"))
        value_row.set_text(value)
        remove = Gtk.Button(label=_("Remove"), halign=Gtk.Align.END, margin_top=6, margin_bottom=6,
                            margin_end=12)
        remove.add_css_class("destructive-action")
        row.add_row(name_row)
        row.add_row(value_row)
        holder = Gtk.ListBoxRow(activatable=False, selectable=False)
        holder.set_child(remove)
        row.add_row(holder)
        entry = {"row": row, "name": name_row, "value": value_row}

        def changed(*_args):
            row.set_title(name_row.get_text() or _("New flag"))
            row.set_subtitle(value_row.get_text())
            self._sync_custom()

        name_row.connect("changed", changed)
        value_row.connect("changed", changed)

        def delete(*_args):
            self.custom.remove(row)
            self.custom_rows.remove(entry)
            self._sync_custom()

        remove.connect("clicked", delete)
        self.custom.add(row)
        self.custom_rows.append(entry)
        if not name:
            row.set_expanded(True)

    def _sync_custom(self):
        for name in [n for n in self.flags if n not in self.preset_flags]:
            del self.flags[name]
        for entry in self.custom_rows:
            name = entry["name"].get_text().strip()
            if name and name not in self.preset_flags:
                self.flags[name] = core.parse_flag_value(entry["value"].get_text())
        self._save()

    def _import_dialog(self):
        dialog = Adw.AlertDialog(
            heading=_("Import fast flags"),
            body=_('Paste JSON like {"Flag": value}. Flags are added to the current ones.'))
        view = Gtk.TextView(wrap_mode=Gtk.WrapMode.CHAR, monospace=True)
        view.set_size_request(420, 220)
        scroller = Gtk.ScrolledWindow(child=view, min_content_height=220)
        scroller.add_css_class("card")
        dialog.set_extra_child(scroller)
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("import", _("Import"))
        dialog.set_response_appearance("import", Adw.ResponseAppearance.SUGGESTED)

        def response(_dialog, result):
            if result != "import":
                return
            buffer = view.get_buffer()
            text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
            try:
                data = json.loads(text)
                if not isinstance(data, dict):
                    raise ValueError
            except ValueError:
                _toast(self.window.toasts, _("This is not a JSON object with flags"))
                return
            existing = {entry["name"].get_text(): entry for entry in self.custom_rows}
            for name, value in data.items():
                if name in self.preset_flags:
                    continue
                if name in existing:
                    existing[name]["value"].set_text(core.format_flag_value(value))
                else:
                    self._add_custom_row(name, core.format_flag_value(value))
            self._sync_custom()
            _toast(self.window.toasts, _("Imported flags: {count}", count=len(data)))

        dialog.connect("response", response)
        dialog.present(self.window)

    def _save(self):
        try:
            core.save_fast_flags(self.flags)
        except OSError as error:
            _toast(self.window.toasts, _("Could not save flags: {error}", error=error))


class SettingsPage(Adw.PreferencesPage):
    def __init__(self, window):
        super().__init__(title=_("Settings"), icon_name="emblem-system-symbolic")
        self.window = window
        settings = window.settings

        interface = Adw.PreferencesGroup(title=_("Interface"))
        codes = list(i18n.LANGUAGES)
        language = Adw.ComboRow(title=_("Language"),
                                model=Gtk.StringList.new(list(i18n.LANGUAGES.values())))
        language.set_selected(codes.index(i18n.language()))
        language.connect("notify::selected", lambda row, _pspec: window.set_language(
            codes[row.get_selected()]))
        interface.add(language)
        self.add(interface)

        game = Adw.PreferencesGroup(title=_("Game"))
        sensitivity = Adw.SpinRow.new_with_range(0.1, 5.0, 0.05)
        sensitivity.set_digits(2)
        sensitivity.set_title(_("Camera sensitivity"))
        sensitivity.set_subtitle(_("Mouse movement multiplier while rotating the camera"))
        sensitivity.set_value(settings["mouse_sensitivity"])
        sensitivity.connect("notify::value", lambda row, _pspec: window.set_setting(
            "mouse_sensitivity", round(row.get_value(), 2)))
        game.add(sensitivity)
        menu_bar = Adw.SwitchRow(title=_("Hide the macOS menu bar"),
                                 subtitle=_("The Roblox, Edit, Window… strip at the top of the game window"),
                                 active=settings["hide_menu_bar"])
        menu_bar.connect("notify::active", lambda row, _pspec: window.set_setting(
            "hide_menu_bar", row.get_active()))
        game.add(menu_bar)
        reopen = Adw.SwitchRow(title=_("Show the launcher after Roblox exits"),
                               active=settings["show_launcher_after_exit"])
        reopen.connect("notify::active", lambda row, _pspec: window.set_setting(
            "show_launcher_after_exit", row.get_active()))
        game.add(reopen)
        self.add(game)

        dns = Adw.PreferencesGroup(
            title=_("DNS for Roblox"),
            description=_("Only Roblox uses this server, the rest of the system keeps its own DNS. "
                          "Helps when some Roblox images or servers do not load."))
        dns_codes = [code for code, _label in DNS_CHOICES]
        server = Adw.ComboRow(title=_("DNS server"),
                              model=Gtk.StringList.new([_(label) for _code, label in DNS_CHOICES]))
        current = settings.get("dns", "system")
        server.set_selected(dns_codes.index(current) if current in dns_codes else 0)
        custom = Adw.EntryRow(title=_("Custom server"))
        custom.set_text(settings.get("dns_custom", ""))
        custom.set_show_apply_button(True)
        custom.set_tooltip_text(_("IP address, optionally with :port. Plain DNS, not encrypted."))
        custom.set_visible(current == "custom")

        def dns_changed(row, _pspec):
            code = dns_codes[row.get_selected()]
            window.set_setting("dns", code)
            custom.set_visible(code == "custom")

        server.connect("notify::selected", dns_changed)
        custom.connect("apply", lambda row: window.set_setting("dns_custom", row.get_text().strip()))
        dns.add(server)
        dns.add(custom)
        self.add(dns)

        roblox = Adw.PreferencesGroup(title="Roblox")
        self.version_row = Adw.ActionRow(title=_("Installed version"),
                                         subtitle=core.installed_version() or _("not found"))
        self.update_button = Gtk.Button(label=_("Check for updates"), valign=Gtk.Align.CENTER)
        self._update_handler = self.update_button.connect("clicked", lambda *_args: self.check_updates())
        self.version_row.add_suffix(self.update_button)
        roblox.add(self.version_row)
        self.progress = Gtk.ProgressBar(show_text=True, margin_top=6, margin_bottom=6,
                                        margin_start=12, margin_end=12, visible=False)
        progress_row = Gtk.ListBoxRow(activatable=False, selectable=False, child=self.progress)
        roblox.add(progress_row)
        self.add(roblox)

        account = Adw.PreferencesGroup(title=_("Account"))
        logout = Adw.ButtonRow(title=_("Sign out"))
        logout.add_css_class("destructive-action")
        logout.connect("activated", lambda *_args: self.logout())
        account.add(logout)
        self.add(account)

        diagnostics = Adw.PreferencesGroup(
            title=_("Diagnostics"),
            description=_("Detailed logs for debugging. They slow the game down, enable only when needed."))
        for key, title in [("diagnostic_signals", "Backtrace on crashes"),
                           ("trace_udp", "Network tracing (UDP)"),
                           ("trace_lock", "Mouse lock tracing"),
                           ("trace_events", "Mouse event tracing"),
                           ("trace_gl", "OpenGL tracing")]:
            row = Adw.SwitchRow(title=_(title), subtitle=core.TRACE_ENV[key], active=settings[key])
            row.connect("notify::active", lambda r, _pspec, k=key: window.set_setting(k, r.get_active()))
            diagnostics.add(row)
        logs = Adw.ButtonRow(title=_("Open logs folder"))
        logs.connect("activated", lambda *_args: Gio.AppInfo.launch_default_for_uri(
            core.LOGS.as_uri(), None))
        diagnostics.add(logs)
        rebuild = Adw.ButtonRow(title=_("Rebuild shim"))
        rebuild.connect("activated", lambda *_args: self.rebuild())
        diagnostics.add(rebuild)
        restart = Adw.ButtonRow(title=_("Restart Darling"))
        restart.connect("activated", lambda *_args: self.restart_darling())
        diagnostics.add(restart)
        self.add(diagnostics)

    def _in_thread(self, work, done):
        def run():
            try:
                result = work()
                GLib.idle_add(done, result, None)
            except Exception as error:  # shown to the user
                GLib.idle_add(done, None, error)
        threading.Thread(target=run, daemon=True).start()

    def _set_update_action(self, label, action):
        self.update_button.set_label(label)
        self.update_button.disconnect(self._update_handler)
        self._update_handler = self.update_button.connect("clicked", lambda *_args: action())

    def check_updates(self, install=False):
        """Looks for a newer client; with install=True also installs it
        (the first install from the Play page)."""
        self.update_button.set_sensitive(False)
        self.update_button.set_label(_("Checking…"))

        def done(result, error):
            self.update_button.set_sensitive(True)
            if error:
                self.update_button.set_label(_("Check for updates"))
                _toast(self.window.toasts, _("Could not check: {error}", error=error))
                return
            version, upload = result
            if version == core.installed_version():
                self.update_button.set_label(_("Check for updates"))
                _toast(self.window.toasts, _("The latest version is installed"))
                return
            self._set_update_action(_("Update to {version}", version=version),
                                    lambda: self.install_update(upload))
            if install:
                self.install_update(upload)

        self._in_thread(core.latest_version, done)

    def install_update(self, upload):
        if self.window.session:
            _toast(self.window.toasts, _("Close Roblox first"))
            return
        self.update_button.set_sensitive(False)
        self.progress.set_visible(True)

        def progress(fraction, text):
            GLib.idle_add(self.progress.set_fraction, fraction)
            GLib.idle_add(self.progress.set_text, text)

        def done(_backup, error):
            self.update_button.set_sensitive(True)
            self._set_update_action(_("Check for updates"), self.check_updates)
            self.progress.set_visible(False)
            self.version_row.set_subtitle(core.installed_version() or _("not found"))
            self.window.play_page.refresh()
            if error:
                _toast(self.window.toasts, _("Update failed: {error}", error=error))
            else:
                _toast(self.window.toasts, _("Roblox updated, the old version is in backups/"))

        self._in_thread(lambda: core.update_roblox(upload, progress), done)

    def logout(self):
        dialog = Adw.AlertDialog(
            heading=_("Sign out?"),
            body=_("The saved Roblox session will be deleted, you will need to sign in again next time."))
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("logout", _("Sign out of Roblox"))
        dialog.set_response_appearance("logout", Adw.ResponseAppearance.DESTRUCTIVE)

        def response(_dialog, result):
            if result == "logout":
                core.logout()
                _toast(self.window.toasts, _("Session deleted"))

        dialog.connect("response", response)
        dialog.present(self.window)

    def rebuild(self):
        _toast(self.window.toasts, _("Building the shim…"))

        def done(result, error):
            ok, output = result if result else (False, str(error))
            _toast(self.window.toasts, _("Shim built") if ok else _("Build failed, details in the terminal"))
            if not ok:
                print(output)

        self._in_thread(core.build_shim, done)

    def restart_darling(self):
        if self.window.session:
            _toast(self.window.toasts, _("Close Roblox first"))
            return
        core.restart_darling()
        _toast(self.window.toasts, _("Darling stopped, it starts with the next game"))
        GLib.timeout_add_seconds(2, lambda: self.window.play_page.refresh() and False)


ABOUT = ("Mac O’ Blox runs the real Roblox client for macOS on Linux through Darling. "
         "It is not made by Roblox and is not affiliated with it.")


def _links():
    """(title, icon, uri) of the project's community pages."""
    links = [("Discord", "macoblox-discord-symbolic", author.DISCORD_URL)]
    if author.GITHUB_URL:
        links.append(("GitHub", "macoblox-github-symbolic", author.GITHUB_URL))
    return links


def _open_uri(window, uri):
    Gtk.UriLauncher.new(uri).launch(window, None, None, None)


class InfoPage(Adw.PreferencesPage):
    def __init__(self, window):
        super().__init__(title=_("Info"), icon_name="help-about-symbolic")
        self.window = window

        about = Adw.PreferencesGroup(title="Mac O’ Blox", description=_(ABOUT))
        self.add(about)

        community = Adw.PreferencesGroup(title=_("Community"))
        for title, icon, uri in _links():
            row = Adw.ActionRow(title=title, activatable=True)
            row.add_prefix(Gtk.Image(icon_name=icon))
            row.add_suffix(Gtk.Image(icon_name="adw-external-link-symbolic"))
            row.connect("activated", lambda *_args, u=uri: _open_uri(window, u))
            community.add(row)
        self.add(community)

        made_by = Adw.PreferencesGroup(title=_("Author"))
        self.avatar = Adw.Avatar(size=48, text=author.NAME, show_initials=True)
        profile = Adw.ActionRow(title=author.NAME, activatable=True,
                                subtitle=_("{user} on Roblox", user="@" + author.ROBLOX_USER))
        profile.add_prefix(self.avatar)
        profile.add_suffix(Gtk.Image(icon_name="adw-external-link-symbolic"))
        profile.connect("activated", lambda *_args: _open_uri(window, author.PROFILE_URL))
        made_by.add(profile)
        self.add(made_by)

        support = Adw.PreferencesGroup(
            title=_("Support the project"),
            description=_("Mac O’ Blox is free. If it helped you, you can thank the author."))
        for title, subtitle, uri in [("Boosty", "Cards from any country", author.BOOSTY_URL),
                                     ("YooMoney", "For Russia", author.YOOMONEY_URL)]:
            row = Adw.ActionRow(title=_(title), subtitle=_(subtitle), activatable=True)
            row.add_suffix(Gtk.Image(icon_name="adw-external-link-symbolic"))
            row.connect("activated", lambda *_args, u=uri: _open_uri(window, u))
            support.add(row)
        self.add(support)

        settings = dict(window.settings)
        threading.Thread(target=lambda: GLib.idle_add(self._show_avatar, author.avatar(settings)),
                         daemon=True).start()

    def _show_avatar(self, path):
        if path:
            try:
                self.avatar.set_custom_image(Gdk.Texture.new_from_filename(str(path)))
            except GLib.Error:
                pass
        return False


class LauncherWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Mac O’ Blox")
        self.set_default_size(560, 680)
        self.settings = core.load_settings()
        i18n.set_language(self.settings.get("language", "en"))
        self.session = None
        self.last_log = None
        self.build("play")

    def build(self, page):
        """(Re)create the interface, e.g. after the language changes."""
        self.toasts = Adw.ToastOverlay()
        self.stack = Adw.ViewStack()
        self.play_page = PlayPage(self)
        self.stack.add_titled_with_icon(self.play_page, "play", _("Play"), "media-playback-start-symbolic")
        self.stack.add_titled_with_icon(FlagsPage(self), "flags", _("Fast flags"), "preferences-other-symbolic")
        self.settings_page = SettingsPage(self)
        self.stack.add_titled_with_icon(self.settings_page, "settings", _("Settings"), "emblem-system-symbolic")
        self.stack.add_titled_with_icon(InfoPage(self), "info", _("Info"), "help-about-symbolic")
        self.stack.set_visible_child_name(page)

        header = Adw.HeaderBar()
        switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        header.set_title_widget(switcher)
        view = Adw.ToolbarView()
        view.add_top_bar(header)
        self.toasts.set_child(self.stack)
        view.set_content(self.toasts)
        self.set_content(view)

    def set_setting(self, key, value):
        self.settings[key] = value
        core.save_settings(self.settings)

    def set_language(self, code):
        if code == i18n.language():
            return
        self.set_setting("language", code)
        i18n.set_language(code)
        # Rebuild after the combo row finished handling its own signal.
        GLib.idle_add(lambda: self.build("settings") and False)

    def play_clicked(self):
        if core.installed_version():
            self.launch()
        else:
            self.stack.set_visible_child_name("settings")
            self.settings_page.check_updates(install=True)

    def launch(self):
        if self.session:
            return
        self.play_page.play.set_sensitive(False)
        self.play_page.play.set_label(_("Starting…"))
        session = core.RobloxSession(self.settings)

        def start():
            try:
                session.start()
                GLib.idle_add(self._started, session, None)
            except Exception as error:
                session.finish()
                GLib.idle_add(self._started, None, error)

        threading.Thread(target=start, daemon=True).start()

    def _started(self, session, error):
        if error:
            self.play_page.refresh()
            _toast(self.toasts, _("Could not start: {error}", error=error))
            return
        self.session = session
        self.last_log = session.log_path
        self.play_page.refresh(running=True)
        # Hide once the game window has had time to appear.
        GLib.timeout_add_seconds(3, self._hide_while_playing)
        GLib.timeout_add(1000, self._watch)

    def _hide_while_playing(self):
        if self.session:
            self.set_visible(False)
        return False

    def _watch(self):
        if not self.session:
            return False
        status = self.session.poll()
        if status is None:
            return True
        self.session = None
        self.play_page.refresh()
        if self.settings.get("show_launcher_after_exit", True):
            self.set_visible(True)
            self.present()
        else:
            self.get_application().quit()
        if status not in (0, -1):
            _toast(self.toasts, _("Roblox exited with code {status}", status=status))
        return False

    def stop(self):
        threading.Thread(target=core.stop_roblox, daemon=True).start()

    def open_last_log(self):
        if self.last_log:
            Gio.AppInfo.launch_default_for_uri(self.last_log.as_uri(), None)


class LauncherApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.window = None

    def do_activate(self):
        if not self.window:
            Gtk.Window.set_default_icon_name("macoblox")
            Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).add_search_path(
                str(core.PROJECT / "launcher" / "icons"))
            self.window = LauncherWindow(self)
            # Keep running while the window is hidden during a game.
            self.hold()
            self.window.connect("close-request", self._close)
        self.window.set_visible(True)
        self.window.present()

    def _close(self, window):
        if window.session:
            # Closing during a game only hides the launcher.
            window.set_visible(False)
            return True
        self.release()
        self.quit()
        return False


def main():
    return LauncherApp().run(None)
