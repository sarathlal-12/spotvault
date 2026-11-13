import sys
import os
import io
import json
import logging
import re
import queue
import signal
import threading
import time
import multiprocessing
import subprocess
import requests
from PIL import Image
from tkinter import filedialog, messagebox
import customtkinter as ctk
from phone_sync import PhoneSyncServer, generate_pin, get_lan_ips, HTTP_PORT
import sources
import updater
import webbrowser

# Explicitly register Windows AppUserModelID so the taskbar displays our custom icon
if os.name == "nt":
    try:
        import ctypes
        app_id = "spotvault.musicdownloader.app.1.0"
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(app_id)
    except Exception:
        pass

    # spotdl runs FFmpeg and yt-dlp helpers for every song. In the windowed exe
    # each of those console programs would pop up its own terminal window.
    # Start every child process hidden instead (asyncio's Popen inherits this).
    _CREATE_NO_WINDOW = 0x08000000
    _orig_popen_init = subprocess.Popen.__init__

    def _hidden_popen_init(self, *args, **kwargs):
        kwargs["creationflags"] = kwargs.get("creationflags", 0) | _CREATE_NO_WINDOW
        _orig_popen_init(self, *args, **kwargs)

    subprocess.Popen.__init__ = _hidden_popen_init

# yt-dlp resolves every PATH folder with os.path.realpath while looking for
# helper programs. Windows can refuse to follow some junctions (WinError 448,
# "untrusted mount point", e.g. other apps' bin links), and Python lets that
# error through, which failed every download. Drop such folders from this
# process's PATH only.
def _drop_unreadable_path_entries():
    entries = os.environ.get("PATH", "").split(os.pathsep)
    keep = []
    for entry in entries:
        if not entry:
            continue
        try:
            os.path.realpath(entry)
        except OSError:
            continue
        keep.append(entry)
    os.environ["PATH"] = os.pathsep.join(keep)


_drop_unreadable_path_entries()

# Prevent Rich wrapping artifacts
os.environ.setdefault("COLUMNS", "160")

CONFIG_FILE = "library_config.json"
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".spot_sync_cache")
os.makedirs(CACHE_DIR, exist_ok=True)
REPORT_FILE = os.path.join(CACHE_DIR, "last_sync_report.json")

APP_VERSION = "1.4.1"

# -------------------------------------------------------------
# Design tokens: "Crimson" (same look as the phone app).
# Forest-green night, charcoal panels, crimson red, sage green.
# Each colour is a (light, dark) pair; customtkinter switches them live.
# -------------------------------------------------------------
COLOR_BG = ("#F4F1EA", "#06110C")          # Window background
COLOR_SIDEBAR = ("#ECE7DC", "#0B1611")     # Side panels
COLOR_SURFACE = ("#FFFFFF", "#171717")     # Raised cards (charcoal)
COLOR_CARD = ("#E8E2D6", "#1F2421")        # Inputs / feed items
COLOR_CARD_HOVER = ("#DCD4C4", "#2A302C")
COLOR_ACCENT = ("#A31C1B", "#A31C1B")      # Crimson red (fills, buttons)
COLOR_ACCENT_HOVER = ("#841615", "#C0262A")
COLOR_ACCENT_TEXT = ("#A31C1B", "#F0605A")  # Crimson for text on the background
COLOR_CYAN = ("#2F6B52", "#9CC5B0")        # Sage green, second accent
COLOR_ON_ACCENT = "#FFFFFF"                # Text on crimson buttons
COLOR_HERO = ("#E9E2D2", "#13201A")
COLOR_HERO_TEXT = ("#2F6B52", "#9CC5B0")
COLOR_TEXT_PRIMARY = ("#06110C", "#F2EFE8")
COLOR_TEXT_MUTED = ("#4F5A54", "#A3ADA7")
COLOR_TEXT_FAINT = ("#7E877F", "#5F6B64")
COLOR_BORDER = ("#D9D1C1", "#26302A")
COLOR_DANGER = ("#A31C1B", "#F0605A")
COLOR_DANGER_SOFT = ("#F6E2DF", "#2A1213")
COLOR_SKIP = ("#5F6B64", "#A3ADA7")
DISPLAY_FONT = "Georgia"                   # Serif headings, like the brand type

ctk.set_appearance_mode("Dark")
ctk.set_default_color_theme("blue")


def is_dark():
    return ctk.get_appearance_mode() == "Dark"


def pick(color):
    """The plain colour string for the current theme (for tk Canvas)."""
    if isinstance(color, (tuple, list)):
        return color[1] if is_dark() else color[0]
    return color


def aurora_image(width, height, dark, title="", subtitle=""):
    """Banner with a crimson light streak and a sage glow (PIL), with text."""
    from PIL import ImageDraw, ImageFilter, ImageFont
    scale = 2
    w, h = width * scale, height * scale
    base = (6, 17, 12) if dark else (244, 241, 234)
    img = Image.new("RGB", (w, h), base)
    glow = Image.new("RGB", (w, h), base)
    d = ImageDraw.Draw(glow)
    crimson = (163, 28, 27) if dark else (232, 168, 160)
    sage = (60, 110, 88) if dark else (190, 216, 200)
    # A tall red light streak (like stage light on the car) and a green haze.
    d.polygon([(int(w * 0.30), -h), (int(w * 0.40), -h), (int(w * 0.48), h * 2), (int(w * 0.22), h * 2)], fill=crimson)
    d.ellipse((int(w * 0.62), int(h * 0.1), int(w * 1.08), int(h * 1.9)), fill=sage)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=h * 0.38))
    img = Image.blend(img, glow, 0.6 if dark else 0.55)
    if title:
        draw = ImageDraw.Draw(img)

        def font(names, size):
            for f in names:
                try:
                    return ImageFont.truetype(f, size * scale)
                except OSError:
                    continue
            return ImageFont.load_default()

        text = (242, 239, 232) if dark else (6, 17, 12)
        muted = (163, 173, 167) if dark else (79, 90, 84)
        red = (240, 96, 90) if dark else (163, 28, 27)
        draw.text((28 * scale, 24 * scale), "L I B R A R Y", font=font(["segoeuib.ttf", "arialbd.ttf"], 10), fill=red)
        draw.text((26 * scale, 40 * scale), title, font=font(["georgiab.ttf", "timesbd.ttf", "segoeuib.ttf"], 34), fill=text)
        if subtitle:
            draw.text((28 * scale, 92 * scale), subtitle, font=font(["segoeui.ttf", "arial.ttf"], 13), fill=muted)
    return img


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
INVALID_NAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def get_resource_path(relative_path):
    """Get absolute path to resource, works for dev and for PyInstaller."""
    try:
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(".")
    return os.path.join(base_path, relative_path)


def clean_folder_name(name):
    name = INVALID_NAME_CHARS.sub("_", name.strip())
    return name.rstrip(" .")


class LogStream:
    encoding = "utf-8"
    errors = "replace"

    def __init__(self, callback):
        self.callback = callback
        self._buffer = ""

    def write(self, text):
        if not text:
            return 0
        self._buffer += text.replace("\r\n", "\n").replace("\r", "\n")
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            self._emit(line)
        return len(text)

    def _emit(self, line):
        line = ANSI_RE.sub("", line).strip()
        if line:
            self.callback(line)

    def flush(self):
        if self._buffer:
            self._emit(self._buffer)
            self._buffer = ""

    def isatty(self):
        return False

    def writable(self):
        return True

    def fileno(self):
        raise OSError("LogStream has no file descriptor")


# -------------------------------------------------------------
# Add Playlist Dialog Modal
# -------------------------------------------------------------
class AddPlaylistDialog(ctk.CTkToplevel):
    def __init__(self, parent, on_add_callback):
        super().__init__(parent)
        self.title("Add New Playlist")
        self.geometry("520x360")
        self.resizable(False, False)
        self.configure(fg_color=COLOR_SURFACE)
        self.transient(parent)
        self.grab_set()

        self.on_add_callback = on_add_callback

        icon_path = get_resource_path("app_icon.ico")
        if os.path.exists(icon_path):
            self.iconbitmap(icon_path)

        lbl_title = ctk.CTkLabel(
            self,
            text="Add Playlist to Library",
            font=ctk.CTkFont(size=18, weight="bold"),
            text_color=COLOR_TEXT_PRIMARY
        )
        lbl_title.pack(pady=(20, 15))

        # URL Input
        ctk.CTkLabel(self, text="Playlist link:", font=ctk.CTkFont(size=12, weight="bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=30)
        self.entry_url = ctk.CTkEntry(
            self,
            placeholder_text="Paste a playlist link",
            height=40,
            fg_color=COLOR_CARD,
            border_color=COLOR_BORDER,
            corner_radius=8
        )
        self.entry_url.pack(fill="x", padx=30, pady=(4, 15))

        # Folder Name Input
        ctk.CTkLabel(self, text="Folder Name (Inside Master Directory):", font=ctk.CTkFont(size=12, weight="bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=30)
        self.entry_folder = ctk.CTkEntry(
            self,
            placeholder_text="e.g. Slow Songs, Gym EDM",
            height=40,
            fg_color=COLOR_CARD,
            border_color=COLOR_BORDER,
            corner_radius=8
        )
        self.entry_folder.pack(fill="x", padx=30, pady=(4, 25))

        # Action Buttons
        btn_box = ctk.CTkFrame(self, fg_color="transparent")
        btn_box.pack(fill="x", padx=30)

        ctk.CTkButton(
            btn_box,
            text="Cancel",
            width=100,
            height=40,
            corner_radius=20,
            fg_color=COLOR_CARD,
            hover_color=COLOR_CARD_HOVER,
            command=self.destroy
        ).pack(side="left")

        ctk.CTkButton(
            btn_box,
            text="Add to Library",
            height=40,
            corner_radius=20,
            font=ctk.CTkFont(size=13, weight="bold"),
            fg_color=COLOR_ACCENT,
            hover_color=COLOR_ACCENT_HOVER,
            text_color=COLOR_ON_ACCENT,
            command=self._confirm
        ).pack(side="right", fill="x", expand=True, padx=(15, 0))

    def _confirm(self):
        raw = self.entry_url.get()
        folder = clean_folder_name(self.entry_folder.get())

        if not raw.strip() or not folder:
            messagebox.showwarning("Missing Info", "Please fill in both the link and the folder name.", parent=self)
            return
        source, url = sources.normalize_url(raw)
        if not url:
            messagebox.showwarning(
                "Link not supported",
                "That link doesn't look like a playlist. Copy the playlist's share link and paste it here.",
                parent=self)
            return

        self.on_add_callback(url, folder)
        self.destroy()


# -------------------------------------------------------------
# Phone Sync Window (connection details for the Android app)
# -------------------------------------------------------------
class PhoneSyncDialog(ctk.CTkToplevel):
    def __init__(self, parent):
        super().__init__(parent)
        self.app = parent
        self.title("Phone Sync")
        self.geometry("460x560")
        self.resizable(False, False)
        self.configure(fg_color=COLOR_SURFACE)
        self.transient(parent)

        icon_path = get_resource_path("app_icon.ico")
        if os.path.exists(icon_path):
            self.after(200, lambda: self.iconbitmap(icon_path))

        ctk.CTkLabel(
            self,
            text="Connect Your Phone",
            font=ctk.CTkFont(size=18, weight="bold"),
            text_color=COLOR_TEXT_PRIMARY
        ).pack(pady=(20, 4))

        ctk.CTkLabel(
            self,
            text="Open SpotVault on your phone (same Wi-Fi).\nIt finds this PC automatically, or type the address below.",
            font=ctk.CTkFont(size=12),
            text_color=COLOR_TEXT_MUTED,
            justify="center"
        ).pack(pady=(0, 14))

        info = ctk.CTkFrame(self, fg_color=COLOR_CARD, corner_radius=12, border_width=1, border_color=COLOR_BORDER)
        info.pack(fill="x", padx=25)

        ctk.CTkLabel(info, text="ADDRESS", font=ctk.CTkFont(size=11, weight="bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=18, pady=(14, 0))
        self.lbl_addr = ctk.CTkLabel(info, text="", font=ctk.CTkFont(size=26, weight="bold"), text_color=COLOR_ACCENT_TEXT, anchor="w", justify="left")
        self.lbl_addr.pack(fill="x", padx=18)

        ctk.CTkLabel(info, text="PIN", font=ctk.CTkFont(size=11, weight="bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=18, pady=(10, 0))
        pin_row = ctk.CTkFrame(info, fg_color="transparent")
        pin_row.pack(fill="x", padx=18, pady=(0, 14))
        self.lbl_pin = ctk.CTkLabel(pin_row, text="", font=ctk.CTkFont(size=26, weight="bold"), text_color=COLOR_TEXT_PRIMARY)
        self.lbl_pin.pack(side="left")
        ctk.CTkButton(
            pin_row,
            text="New PIN",
            width=80,
            height=28,
            corner_radius=14,
            fg_color=COLOR_SURFACE,
            hover_color=COLOR_CARD_HOVER,
            command=self._new_pin
        ).pack(side="right")

        self.lbl_state = ctk.CTkLabel(self, text="", font=ctk.CTkFont(size=12, weight="bold"), wraplength=400, justify="center")
        self.lbl_state.pack(pady=(12, 6))

        ctk.CTkLabel(self, text="ACTIVITY", font=ctk.CTkFont(size=11, weight="bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=25)
        self.feed = ctk.CTkTextbox(self, height=150, fg_color=COLOR_SIDEBAR, border_width=1, border_color=COLOR_BORDER, font=ctk.CTkFont(size=11))
        self.feed.pack(fill="both", expand=True, padx=25, pady=(4, 10))

        ctk.CTkLabel(
            self,
            text="If the phone can't connect, allow SpotVault on 'Private networks'\nwhen Windows Firewall asks.",
            font=ctk.CTkFont(size=10),
            text_color=COLOR_TEXT_MUTED,
            justify="center"
        ).pack(pady=(0, 14))

        self.refresh()

    def _new_pin(self):
        if messagebox.askyesno("New PIN", "Phones paired with the old PIN must re-enter the new one. Continue?", parent=self):
            self.app.sync_pin = generate_pin()
            self.app._save_config()
            self.refresh()

    def refresh(self):
        server = self.app.phone_server
        ips = get_lan_ips()
        if ips:
            self.lbl_addr.configure(text="\n".join(f"{ip}:{HTTP_PORT}" for ip in ips[:3]))
        else:
            self.lbl_addr.configure(text="No network found")
        pin = self.app.sync_pin
        self.lbl_pin.configure(text=f"{pin[:3]} {pin[3:]}")

        if server.running:
            self.lbl_state.configure(text="● Ready for phone sync", text_color=COLOR_ACCENT_TEXT)
        else:
            self.lbl_state.configure(text=f"✕ Sync server not running: {server.error}", text_color=COLOR_DANGER)

        self.feed.configure(state="normal")
        self.feed.delete("1.0", "end")
        self.feed.insert("end", "\n".join(self.app.phone_events[-200:]) or "Waiting for a phone…")
        self.feed.see("end")
        self.feed.configure(state="disabled")

# -------------------------------------------------------------
# Main Application
# -------------------------------------------------------------
class VaultApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        self.title(f"SpotVault {APP_VERSION}")
        self.geometry("1100x700")
        self.minsize(980, 600)
        self.after(0, lambda: self.state("zoomed"))
        self.configure(fg_color=COLOR_BG)

        # Set Window Icon
        icon_path = get_resource_path("app_icon.ico")
        if os.path.exists(icon_path):
            self.iconbitmap(icon_path)

        self.master_folder = os.path.join(os.path.expanduser("~"), "Music")
        self.playlists = []  # List of dicts: {"url": ..., "folder": ..., "title": ..., "img_path": ..., "has_synced": ...}
        self.is_running = False
        self.msg_queue = queue.Queue()
        self.active_tasks = []
        self.sync_pin = ""
        self.skip_update = ""
        self.phone_events = []
        self.phone_dialog = None
        self.search_dialog = None
        self.report_window = None
        self.theme = "dark"
        self._current_playlist = ""

        self._load_config()
        ctk.set_appearance_mode("Light" if self.theme == "light" else "Dark")
        self.report = self._load_report()
        if not self.sync_pin:
            self.sync_pin = generate_pin()
            self._save_config()

        # Wi-Fi server for the Android companion app
        self.phone_server = PhoneSyncServer(
            get_state=lambda: (self.master_folder, list(self.playlists)),
            get_pin=lambda: self.sync_pin,
            on_event=lambda text: self._post("phone", text),
        )
        self.phone_server.on_library_changed = lambda: self._post("call", self._render_library_cards)
        self.phone_server.start()

        self._build_ui()

        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.update_dialog = None
        # Quiet update check a few seconds after start (never blocks the UI).
        self.after(4000, lambda: self._check_updates(manual=False))
        self.after(100, self._poll_queue)

    def _load_config(self):
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    self.master_folder = data.get("master_folder", self.master_folder)
                    self.playlists = data.get("playlists", [])
                    self.sync_pin = str(data.get("sync_pin", ""))
                    self.skip_update = str(data.get("skip_update", ""))
                    self.theme = "light" if data.get("theme") == "light" else "dark"
            except Exception:
                pass

    def _save_config(self):
        data = {
            "master_folder": self.master_folder,
            "playlists": self.playlists,
            "sync_pin": self.sync_pin,
            "skip_update": self.skip_update,
            "theme": self.theme,
        }
        try:
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=4)
        except Exception:
            pass

    # ---------------------------------------------------------------
    # UI
    # ---------------------------------------------------------------
    def _font(self, size, weight="normal"):
        return ctk.CTkFont(family="Segoe UI", size=size, weight=weight)

    def _build_ui(self):
        self._cover_cache = {}
        self._grid_cols = 0
        self.counts = {"done": 0, "skip": 0, "fail": 0}
        self._ring_value = 0.0
        self._ring_phase = 0
        self._ring_label = "Ready"
        self._banner_key = None

        # ---------- Sidebar ----------
        sidebar = ctk.CTkFrame(self, fg_color=COLOR_SIDEBAR, width=248, corner_radius=0,
                               border_width=0)
        sidebar.pack(side="left", fill="y")
        sidebar.pack_propagate(False)

        brand = ctk.CTkFrame(sidebar, fg_color="transparent")
        brand.pack(fill="x", padx=20, pady=(24, 20))
        logo = ctk.CTkFrame(brand, width=36, height=36, corner_radius=11, fg_color=COLOR_ACCENT)
        logo.pack(side="left")
        logo.pack_propagate(False)
        ctk.CTkLabel(logo, text="♪", text_color=COLOR_ON_ACCENT, font=self._font(18, "bold")).place(relx=0.5, rely=0.5, anchor="center")
        ctk.CTkLabel(brand, text="SpotVault", font=ctk.CTkFont(family=DISPLAY_FONT, size=22, weight="bold"), text_color=COLOR_TEXT_PRIMARY).pack(side="left", padx=(10, 0))

        nav = ctk.CTkFrame(sidebar, fg_color="transparent")
        nav.pack(fill="x", padx=12, pady=(0, 14))
        self._nav_button(nav, "▤    Library", self._render_library_cards, active=True)
        self._nav_button(nav, "⌕    Search songs", self._open_search_dialog)
        report_btn = self._nav_button(nav, "☰    Sync report", self._open_report)
        self.lbl_report_badge = ctk.CTkLabel(report_btn, text="", width=26, height=20, corner_radius=10,
                                             fg_color=COLOR_DANGER, text_color="#FFFFFF", font=self._font(11, "bold"))
        self.lbl_report_badge.bind("<Button-1>", lambda e: self._open_report())

        # Library stats
        stats = self._side_card(sidebar)
        ctk.CTkLabel(stats, text="YOUR LIBRARY", font=self._font(11, "bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14, pady=(12, 6))
        self.lbl_stat_playlists = self._stat_row(stats, "Playlists")
        self.lbl_stat_songs = self._stat_row(stats, "Songs")
        self.lbl_stat_size = self._stat_row(stats, "On disk", last=True)

        # Phone sync
        phone = self._side_card(sidebar, pady=(12, 0))
        row = ctk.CTkFrame(phone, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(12, 2))
        ctk.CTkLabel(row, text="PHONE SYNC", font=self._font(11, "bold"), text_color=COLOR_TEXT_MUTED).pack(side="left")
        ok = self.phone_server.running
        ctk.CTkLabel(row, text="● Ready" if ok else "● Off", font=self._font(11, "bold"),
                     text_color=COLOR_CYAN if ok else COLOR_DANGER).pack(side="right")
        ctk.CTkLabel(phone, text="Send playlists to the\nSpotVault phone app.", justify="left",
                     font=self._font(12), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14)
        ctk.CTkButton(
            phone, text="Connect phone", height=36, corner_radius=18,
            fg_color="transparent", hover_color=COLOR_CARD_HOVER, border_width=1, border_color=COLOR_BORDER,
            text_color=COLOR_TEXT_PRIMARY, font=self._font(13, "bold"), command=self._open_phone_dialog
        ).pack(fill="x", padx=14, pady=(10, 14))

        # Version + update check (very bottom of sidebar)
        ver = ctk.CTkFrame(sidebar, fg_color="transparent")
        ver.pack(side="bottom", fill="x", padx=14, pady=(0, 12))
        ctk.CTkLabel(ver, text=f"v{APP_VERSION}", font=self._font(11), text_color=COLOR_TEXT_FAINT).pack(side="left", padx=(4, 0))
        self.btn_update = ctk.CTkButton(ver, text="Check for updates", height=26, width=120, corner_radius=13,
                                        fg_color="transparent", hover_color=COLOR_CARD, border_width=1,
                                        border_color=COLOR_BORDER, text_color=COLOR_TEXT_MUTED,
                                        font=self._font(11), command=lambda: self._check_updates(manual=True))
        self.btn_update.pack(side="right")

        # Storage folder (bottom of sidebar)
        folder = self._side_card(sidebar, side="bottom", pady=14)
        ctk.CTkLabel(folder, text="MUSIC FOLDER", font=self._font(11, "bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14, pady=(12, 2))
        self.lbl_master_path = ctk.CTkLabel(folder, text="", font=self._font(12), text_color=COLOR_TEXT_PRIMARY,
                                            anchor="w", justify="left", wraplength=190)
        self.lbl_master_path.pack(fill="x", padx=14)
        btns = ctk.CTkFrame(folder, fg_color="transparent")
        btns.pack(fill="x", padx=14, pady=(10, 14))
        ctk.CTkButton(btns, text="Open", height=30, width=80, corner_radius=15, fg_color=COLOR_CARD,
                      hover_color=COLOR_CARD_HOVER, text_color=COLOR_TEXT_PRIMARY, font=self._font(12, "bold"),
                      command=self._open_master_folder).pack(side="left", expand=True, fill="x", padx=(0, 4))
        ctk.CTkButton(btns, text="Change", height=30, width=80, corner_radius=15, fg_color=COLOR_CARD,
                      hover_color=COLOR_CARD_HOVER, text_color=COLOR_TEXT_PRIMARY, font=self._font(12, "bold"),
                      command=self._change_master_folder).pack(side="left", expand=True, fill="x", padx=(4, 0))

        # ---------- Activity panel (right) ----------
        self.right_pane = ctk.CTkFrame(self, width=300, fg_color=COLOR_SIDEBAR, corner_radius=0)
        self.right_pane.pack(side="right", fill="y")
        self.right_pane.pack_propagate(False)

        head = ctk.CTkFrame(self.right_pane, fg_color="transparent")
        head.pack(fill="x", padx=18, pady=(24, 6))
        ctk.CTkLabel(head, text="Activity", font=ctk.CTkFont(family=DISPLAY_FONT, size=20, weight="bold"), text_color=COLOR_TEXT_PRIMARY).pack(side="left")
        self.lbl_status = ctk.CTkLabel(head, text="Idle", font=self._font(11, "bold"), text_color=COLOR_ON_ACCENT,
                                       fg_color=COLOR_TEXT_FAINT, corner_radius=10, height=22, width=70)
        self.lbl_status.pack(side="right")

        import tkinter as tk
        scale = ctk.ScalingTracker.get_widget_scaling(self)
        self._ring_px = int(168 * scale)
        self.ring = tk.Canvas(self.right_pane, width=self._ring_px, height=self._ring_px, highlightthickness=0,
                              bd=0, bg=pick(COLOR_SIDEBAR))
        self.ring.pack(pady=(6, 4))
        self._draw_ring()

        counters = ctk.CTkFrame(self.right_pane, fg_color="transparent")
        counters.pack(fill="x", padx=14, pady=(8, 8))
        self.lbl_cnt_done = self._counter(counters, "Downloaded", COLOR_CYAN)
        self.lbl_cnt_skip = self._counter(counters, "Skipped", COLOR_TEXT_MUTED)
        self.lbl_cnt_fail = self._counter(counters, "Failed", COLOR_DANGER)

        self.btn_why = ctk.CTkButton(self.right_pane, text="See why songs failed or were skipped", height=34,
                                     corner_radius=17, fg_color=COLOR_DANGER_SOFT, hover_color=COLOR_CARD_HOVER,
                                     text_color=COLOR_DANGER, font=self._font(12, "bold"), command=self._open_report)

        self.feed_scroll = ctk.CTkScrollableFrame(self.right_pane, fg_color="transparent", corner_radius=0)
        self.feed_scroll.pack(fill="both", expand=True, padx=6, pady=(0, 10))
        self._feed_placeholder()

        # ---------- Main area ----------
        main = ctk.CTkFrame(self, fg_color=COLOR_BG, corner_radius=0)
        main.pack(side="left", fill="both", expand=True)

        self.banner = ctk.CTkLabel(main, text="", height=140, width=10, anchor="w", fg_color=COLOR_BG)
        self.banner.pack(fill="x")
        self._banner_subtitle = ""
        self._banner_job = None
        main.bind("<Configure>", self._on_main_resize)

        actions = ctk.CTkFrame(main, fg_color="transparent")
        actions.pack(fill="x", padx=28, pady=(14, 4))
        self.btn_sync_all = ctk.CTkButton(
            actions, text="Sync all", height=44, width=140, corner_radius=22,
            fg_color=COLOR_ACCENT, hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT,
            font=self._font(14, "bold"), command=self._sync_all_playlists
        )
        self.btn_sync_all.pack(side="left")
        for text, cmd in (("+  Add playlist", self._open_add_dialog), ("Search songs", self._open_search_dialog)):
            ctk.CTkButton(
                actions, text=text, height=44, width=150, corner_radius=22,
                fg_color=COLOR_SURFACE, hover_color=COLOR_CARD_HOVER, border_width=1, border_color=COLOR_BORDER,
                text_color=COLOR_TEXT_PRIMARY, font=self._font(14, "bold"), command=cmd
            ).pack(side="left", padx=(12, 0))
        self.btn_theme = ctk.CTkButton(
            actions, text="", width=44, height=44, corner_radius=14, fg_color=COLOR_SURFACE,
            hover_color=COLOR_CARD_HOVER, border_width=1, border_color=COLOR_BORDER, text_color=COLOR_ACCENT_TEXT,
            font=self._font(18, "bold"), command=self._toggle_theme)
        self.btn_theme.pack(side="right")
        self._update_theme_button()

        # Summary of the last sync, with a way into the report.
        self.last_card = ctk.CTkFrame(main, fg_color=COLOR_SURFACE, corner_radius=20, border_width=1,
                                      border_color=COLOR_BORDER)
        inner = ctk.CTkFrame(self.last_card, fg_color="transparent")
        inner.pack(fill="x", padx=20, pady=14)
        left = ctk.CTkFrame(inner, fg_color="transparent")
        left.pack(side="left", fill="x", expand=True)
        self.lbl_last_when = ctk.CTkLabel(left, text="", font=self._font(11, "bold"), text_color=COLOR_ACCENT_TEXT, anchor="w")
        self.lbl_last_when.pack(fill="x")
        self.lbl_last_title = ctk.CTkLabel(left, text="", font=ctk.CTkFont(family=DISPLAY_FONT, size=18, weight="bold"), text_color=COLOR_TEXT_PRIMARY, anchor="w")
        self.lbl_last_title.pack(fill="x")
        ctk.CTkButton(inner, text="See why", height=38, width=96, corner_radius=19, fg_color=COLOR_TEXT_PRIMARY,
                      hover_color=COLOR_TEXT_MUTED, text_color=COLOR_BG, font=self._font(13, "bold"),
                      command=self._open_report).pack(side="right", padx=(16, 0))
        self.last_counts = {}
        for kind, label, color in (("fail", "failed", COLOR_DANGER), ("skip", "skipped", COLOR_TEXT_PRIMARY),
                                   ("done", "downloaded", COLOR_CYAN)):
            box = ctk.CTkFrame(inner, fg_color="transparent")
            box.pack(side="right", padx=12)
            v = ctk.CTkLabel(box, text="0", font=self._font(22, "bold"), text_color=color)
            v.pack(anchor="e")
            ctk.CTkLabel(box, text=label, font=self._font(11), text_color=COLOR_TEXT_MUTED).pack(anchor="e")
            self.last_counts[kind] = v

        self.cards_scroll = ctk.CTkScrollableFrame(main, fg_color="transparent", corner_radius=0)
        self.cards_scroll.pack(fill="both", expand=True, padx=16, pady=(6, 12))
        self.cards_scroll._parent_canvas.bind("<Configure>", self._on_grid_resize, add="+")

        self._render_library_cards()
        self._refresh_last_sync()

    # ------------------------------------------------------------ small builders
    def _nav_button(self, parent, text, command, active=False):
        btn = ctk.CTkButton(parent, text=text, anchor="w", height=42, corner_radius=12,
                            fg_color=COLOR_HERO if active else "transparent", hover_color=COLOR_CARD_HOVER,
                            text_color=COLOR_TEXT_PRIMARY if active else COLOR_TEXT_MUTED,
                            font=self._font(14, "bold" if active else "normal"), command=command)
        btn.pack(fill="x", pady=2)
        return btn

    def _side_card(self, parent, side="top", pady=0):
        card = ctk.CTkFrame(parent, fg_color=COLOR_SURFACE, corner_radius=16, border_width=1, border_color=COLOR_BORDER)
        card.pack(side=side, fill="x", padx=14, pady=pady)
        return card

    # ------------------------------------------------------------ theme
    def _toggle_theme(self):
        ctk.set_appearance_mode("Light" if is_dark() else "Dark")
        self.theme = "dark" if is_dark() else "light"
        self._save_config()
        self._update_theme_button()
        self.ring.configure(bg=pick(COLOR_SIDEBAR))
        self._draw_ring()

    def _update_theme_button(self):
        self.btn_theme.configure(text="☀" if is_dark() else "☾")

    def _on_main_resize(self, event):
        # Redraw the banner at the new width once resizing pauses.
        if self._banner_job is not None:
            self.after_cancel(self._banner_job)
        self._banner_job = self.after(250, lambda: self._update_banner(self._banner_subtitle))

    def _update_banner(self, subtitle):
        self._banner_subtitle = subtitle
        scale = ctk.ScalingTracker.get_widget_scaling(self)
        w = max(400, int(self.banner.master.winfo_width() / scale)) if self.banner.master.winfo_width() > 1 else 800
        h = 140
        key = (subtitle, w)
        if key == self._banner_key:
            return
        self._banner_key = key
        img = ctk.CTkImage(light_image=aurora_image(w, h, False, "Your Playlists", subtitle),
                           dark_image=aurora_image(w, h, True, "Your Playlists", subtitle), size=(w, h))
        self.banner.configure(image=img)
        self._banner_img = img

    # ------------------------------------------------------------ progress ring
    def _set_progress(self, value):
        self._ring_value = max(0.0, min(1.0, float(value)))
        self._draw_ring()

    def _draw_ring(self):
        c = self.ring
        c.delete("all")
        s = self._ring_px
        pad, width = s * 0.08, max(6, int(s * 0.07))
        box = (pad, pad, s - pad, s - pad)
        c.create_arc(*box, start=0, extent=359.9, style="arc", width=width, outline=pick(COLOR_CARD))
        if self._ring_value > 0:
            c.create_arc(*box, start=90, extent=-359.9 * self._ring_value, style="arc", width=width,
                         outline=pick(COLOR_ACCENT))
        if self.is_running:
            p = pad * 0.35
            c.create_arc(p, p, s - p, s - p, start=self._ring_phase, extent=50, style="arc",
                         width=max(2, int(s * 0.018)), outline=pick(COLOR_CYAN))
        c.create_text(s / 2, s / 2 - s * 0.05, text=f"{int(round(self._ring_value * 100))}%",
                      fill=pick(COLOR_TEXT_PRIMARY), font=("Segoe UI", int(s * 0.13), "bold"))
        c.create_text(s / 2, s / 2 + s * 0.12, text=self._ring_label, fill=pick(COLOR_TEXT_MUTED),
                      font=("Segoe UI", max(8, int(s * 0.055))))

    def _tick_ring(self):
        if not self.is_running:
            self._draw_ring()
            return
        self._ring_phase = (self._ring_phase - 8) % 360
        self._draw_ring()
        self.after(45, self._tick_ring)

    # ------------------------------------------------------------ sync report
    def _open_report(self):
        if self.report_window is not None and self.report_window.winfo_exists():
            self.report_window.reload()
            self.report_window.focus()
            return
        self.report_window = SyncReportWindow(self)

    def _load_report(self):
        try:
            with open(REPORT_FILE, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data.get("entries"), list):
                return data
        except (OSError, ValueError, AttributeError):
            pass
        return None

    def _save_report(self):
        try:
            tmp = REPORT_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.report, f, indent=1)
            os.replace(tmp, REPORT_FILE)
        except OSError:
            pass

    def _report_counts(self):
        counts = {"done": 0, "skip": 0, "fail": 0}
        for e in (self.report or {}).get("entries", []):
            if e.get("kind") in counts:
                counts[e["kind"]] += 1
        return counts

    def _refresh_last_sync(self):
        rep = self.report
        if not rep or not rep.get("entries"):
            self.last_card.pack_forget()
            self.lbl_report_badge.place_forget()
            return
        counts = self._report_counts()
        for kind, lbl in self.last_counts.items():
            lbl.configure(text=str(counts[kind]))
        names = rep.get("playlists") or []
        what = names[0] if len(names) == 1 else f"{len(names)} playlists" if names else "Your songs"
        started = rep.get("started", 0)
        finished = rep.get("finished") or started
        mins = max(1, round((finished - started) / 60)) if finished and started else 0
        when = time.strftime("%d %b, %H:%M", time.localtime(finished)) if finished else ""
        self.lbl_last_when.configure(text=f"LAST SYNC · {when}".upper())
        self.lbl_last_title.configure(text=f"{what} finished in {mins} min" if mins else f"{what} synced")
        self.last_card.pack(fill="x", padx=28, pady=(12, 4), before=self.cards_scroll._parent_frame)
        if counts["fail"]:
            self.lbl_report_badge.configure(text=str(counts["fail"]))
            self.lbl_report_badge.place(relx=1.0, x=-10, rely=0.5, anchor="e")
        else:
            self.lbl_report_badge.place_forget()

    def _retry_playlists(self, folders):
        if self.is_running:
            messagebox.showinfo("Busy", "A sync is already running. Try again when it finishes.")
            return
        tasks = []
        for pl in self.playlists:
            if pl.get("folder") in folders and self._verify_folder_integrity(pl):
                tasks.append(self._playlist_task(pl))
        if not tasks:
            messagebox.showinfo("Retry", "Those playlists are no longer in your library.")
            return
        self.active_tasks = tasks
        self._start_sync()

    def _stat_row(self, parent, label, last=False):
        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(0, 12 if last else 4))
        ctk.CTkLabel(row, text=label, font=self._font(13), text_color=COLOR_TEXT_MUTED).pack(side="left")
        val = ctk.CTkLabel(row, text="–", font=self._font(13, "bold"), text_color=COLOR_TEXT_PRIMARY)
        val.pack(side="right")
        return val

    def _counter(self, parent, label, color):
        box = ctk.CTkFrame(parent, fg_color=COLOR_SURFACE, corner_radius=8)
        box.pack(side="left", expand=True, fill="x", padx=4)
        val = ctk.CTkLabel(box, text="0", font=self._font(18, "bold"), text_color=color)
        val.pack(pady=(6, 0))
        ctk.CTkLabel(box, text=label, font=self._font(10), text_color=COLOR_TEXT_MUTED).pack(pady=(0, 6))
        return val

    def _feed_placeholder(self):
        self._placeholder = ctk.CTkLabel(self.feed_scroll, text="Nothing yet.\nPress Sync to download new songs.",
                     font=self._font(12), text_color=COLOR_TEXT_FAINT, justify="center")
        self._placeholder.pack(pady=60)

    def _folder_stats(self, folder):
        path = os.path.join(self.master_folder, folder)
        count, size = 0, 0
        try:
            for e in os.scandir(path):
                if e.is_file() and e.name.lower().endswith((".m4a", ".mp3", ".flac", ".wav", ".ogg", ".opus")):
                    count += 1
                    size += e.stat().st_size
        except OSError:
            pass
        return count, size

    def _cover_image(self, img_path, size):
        key = (img_path, size)
        if key in self._cover_cache:
            return self._cover_cache[key]
        img = None
        if img_path and os.path.exists(img_path):
            try:
                from PIL import ImageDraw
                pil = Image.open(img_path).convert("RGB").resize((size * 2, size * 2), Image.Resampling.LANCZOS)
                mask = Image.new("L", pil.size, 0)
                ImageDraw.Draw(mask).rounded_rectangle((0, 0, *pil.size), radius=16, fill=255)
                pil.putalpha(mask)
                img = ctk.CTkImage(light_image=pil, dark_image=pil, size=(size, size))
            except Exception:
                img = None
        self._cover_cache[key] = img
        return img

    def _on_grid_resize(self, event):
        scale = ctk.ScalingTracker.get_widget_scaling(self)
        cols = max(1, int((event.width / scale - 10) // 200))
        if self.playlists and cols != self._grid_cols:
            self._render_library_cards()

    def _render_library_cards(self):
        """Draws saved playlists as a grid of cover-art tiles."""
        for widget in self.cards_scroll.winfo_children():
            widget.destroy()

        self.lbl_master_path.configure(text=self.master_folder)

        total_songs, total_size = 0, 0
        stats = []
        for pl in self.playlists:
            c, s = self._folder_stats(pl.get("folder", ""))
            stats.append((c, s))
            total_songs += c
            total_size += s
        self.lbl_stat_playlists.configure(text=str(len(self.playlists)))
        self.lbl_stat_songs.configure(text=str(total_songs))
        if total_size < 1024 ** 3:
            self.lbl_stat_size.configure(text=f"{total_size / 1024 / 1024:.0f} MB")
        else:
            self.lbl_stat_size.configure(text=f"{total_size / 1024 ** 3:.2f} GB")
        self._update_banner(f"{len(self.playlists)} playlists  ·  {total_songs} songs  ·  {self.lbl_stat_size.cget('text')}")

        if not self.playlists:
            self._grid_cols = 0
            box = ctk.CTkFrame(self.cards_scroll, fg_color="transparent")
            box.pack(fill="both", expand=True, pady=70)
            ctk.CTkLabel(box, text="♪", font=self._font(54), text_color=COLOR_ACCENT_TEXT).pack()
            ctk.CTkLabel(box, text="No playlists yet", font=ctk.CTkFont(family=DISPLAY_FONT, size=24, weight="bold"),
                         text_color=COLOR_TEXT_PRIMARY).pack(pady=(4, 4))
            ctk.CTkLabel(box, text="Paste a playlist link to start your offline library.",
                         font=self._font(13), text_color=COLOR_TEXT_MUTED).pack()
            ctk.CTkButton(box, text="+  Add playlist", height=40, corner_radius=20, fg_color=COLOR_ACCENT,
                          hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT, font=self._font(13, "bold"),
                          command=self._open_add_dialog).pack(pady=18)
            return

        scale = ctk.ScalingTracker.get_widget_scaling(self)
        width = self.cards_scroll._parent_canvas.winfo_width()
        cols = max(1, int((width / scale - 10) // 200)) if width > 1 else 3
        self._grid_cols = cols
        # Clear column settings left over from a wider layout.
        for c in range(12):
            self.cards_scroll.grid_columnconfigure(c, weight=0, uniform="", minsize=0)
        for c in range(cols):
            self.cards_scroll.grid_columnconfigure(c, weight=1, uniform="tile")

        for idx, pl in enumerate(self.playlists):
            count, size = stats[idx]
            tile = self._playlist_tile(idx, pl, count, size)
            tile.grid(row=idx // cols, column=idx % cols, padx=8, pady=8, sticky="nsew")

    def _playlist_tile(self, idx, pl, count, size):
        tile = ctk.CTkFrame(self.cards_scroll, fg_color=COLOR_SURFACE, corner_radius=20, border_width=1,
                            border_color=COLOR_BORDER)
        cover = self._cover_image(pl.get("img_path", ""), 164)
        art = ctk.CTkLabel(tile, text="" if cover else "♪", image=cover, width=164, height=164,
                           fg_color="transparent" if cover else COLOR_HERO, corner_radius=14,
                           font=ctk.CTkFont(family=DISPLAY_FONT, size=48, weight="bold"), text_color=COLOR_ACCENT_TEXT)
        art.pack(padx=12, pady=(12, 8))

        src = sources.source_label(sources.detect_source(pl.get("url", "")))
        ctk.CTkLabel(tile, text=src.upper(), font=self._font(10, "bold"), text_color=COLOR_CYAN,
                     anchor="w").pack(fill="x", padx=16)
        ctk.CTkLabel(tile, text=pl.get("title") or "Playlist", font=ctk.CTkFont(family=DISPLAY_FONT, size=15, weight="bold"),
                     text_color=COLOR_TEXT_PRIMARY, anchor="w", wraplength=165, justify="left").pack(fill="x", padx=16)

        target = os.path.join(self.master_folder, pl.get("folder", ""))
        if pl.get("has_synced", False) and not os.path.exists(target):
            sub, color = "Folder missing", COLOR_DANGER
        elif not pl.get("has_synced", False):
            sub, color = "Not synced yet", COLOR_TEXT_MUTED
        else:
            sub, color = f"{count} songs  ·  {size / 1024 / 1024:.0f} MB", COLOR_TEXT_MUTED
        ctk.CTkLabel(tile, text=sub, font=self._font(12), text_color=color, anchor="w").pack(fill="x", padx=16, pady=(2, 0))

        row = ctk.CTkFrame(tile, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(10, 14))
        ctk.CTkButton(row, text="Sync", height=34, width=84, corner_radius=17, fg_color=COLOR_ACCENT,
                      hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT, font=self._font(12, "bold"),
                      command=lambda p=pl: self._sync_single_playlist(p)).pack(side="left")
        ctk.CTkButton(row, text="✕", height=34, width=34, corner_radius=17, fg_color=COLOR_CARD,
                      hover_color=COLOR_DANGER, text_color=COLOR_TEXT_MUTED, font=self._font(12, "bold"),
                      command=lambda i=idx: self._remove_playlist(i)).pack(side="right")
        return tile

    def _open_add_dialog(self):
        AddPlaylistDialog(self, self._handle_add_playlist)

    def _open_phone_dialog(self):
        if self.phone_dialog is not None and self.phone_dialog.winfo_exists():
            self.phone_dialog.refresh()
            self.phone_dialog.focus()
            return
        self.phone_dialog = PhoneSyncDialog(self)

    # ---------------------------------------------------------------
    # Updates
    # ---------------------------------------------------------------
    def _check_updates(self, manual):
        if manual:
            self.btn_update.configure(state="disabled", text="Checking…")

        def work():
            try:
                info, error = updater.check_latest(), None
            except Exception as e:
                info, error = None, e
            self._post("call", lambda: self._update_result(info, error, manual))

        threading.Thread(target=work, daemon=True).start()

    def _update_result(self, info, error, manual):
        if manual:
            self.btn_update.configure(state="normal", text="Check for updates")
        if error is not None:
            if manual:
                messagebox.showwarning("Update check", "Couldn't check for updates. Check your internet connection and try again.")
            return
        newer = info is not None and updater.is_newer(info["version"], APP_VERSION)
        if not newer:
            if manual:
                messagebox.showinfo("Update check", f"You're on the latest version (v{APP_VERSION}).")
            return
        if not manual and info["version"] == self.skip_update:
            return
        if self.update_dialog is not None and self.update_dialog.winfo_exists():
            self.update_dialog.focus()
            return
        self.update_dialog = UpdateDialog(self, info)

    def _open_search_dialog(self, query="", folder=""):
        if not self.playlists:
            messagebox.showinfo("No playlists yet", "Add a playlist first. Search results are saved into one of your playlist folders.")
            return
        if self.search_dialog is not None and self.search_dialog.winfo_exists():
            if not query:
                self.search_dialog.focus()
                return
            self.search_dialog.destroy()
        self.search_dialog = SearchDialog(self, query, folder)

    def _handle_add_playlist(self, url, folder):
        meta = sources.fetch_metadata(sources.detect_source(url), url)
        title = meta["title"]
        thumb_url = meta["thumbnail_url"]

        # Immediately create folder on disk to avoid missing folder flags
        target_dir = os.path.join(self.master_folder, folder)
        try:
            os.makedirs(target_dir, exist_ok=True)
        except Exception as e:
            messagebox.showerror("Error", f"Could not create folder:\n{e}")
            return

        cached_img_path = ""
        if thumb_url:
            try:
                res = requests.get(thumb_url, timeout=5)
                if res.status_code == 200:
                    cached_img_path = os.path.join(CACHE_DIR, f"{folder}_{len(self.playlists)}.png")
                    with open(cached_img_path, "wb") as f:
                        f.write(res.content)
            except Exception:
                pass

        new_item = {
            "url": url,
            "folder": folder,
            "title": title,
            "img_path": cached_img_path,
            "has_synced": False
        }
        self.playlists.append(new_item)
        self._save_config()
        self._render_library_cards()

    def _remove_playlist(self, index):
        if messagebox.askyesno("Confirm Removal", f"Remove '{self.playlists[index]['title']}' from your saved library?"):
            del self.playlists[index]
            self._save_config()
            self._render_library_cards()

    def _change_master_folder(self):
        chosen = filedialog.askdirectory(initialdir=self.master_folder)
        if chosen:
            self.master_folder = os.path.normpath(chosen)
            self._save_config()
            self._render_library_cards()

    def _open_master_folder(self):
        if os.path.exists(self.master_folder):
            if os.name == "nt":
                os.startfile(self.master_folder)
            else:
                subprocess.Popen(["xdg-open", self.master_folder])

    def _verify_folder_integrity(self, playlist_item):
        """Only triggers recovery prompt if a previously synced folder was removed."""
        folder_name = playlist_item["folder"]
        target_dir = os.path.join(self.master_folder, folder_name)

        if not playlist_item.get("has_synced", False):
            os.makedirs(target_dir, exist_ok=True)
            return target_dir

        if not os.path.exists(target_dir):
            dialog = ctk.CTkInputDialog(
                text=(
                    f"Warning: Folder '{folder_name}' was deleted!\n\n"
                    f"Type a new folder name, or keep it as '{folder_name}' to recreate:"
                ),
                title="Folder Missing Recovery"
            )
            new_name = dialog.get_input()
            if new_name and clean_folder_name(new_name):
                playlist_item["folder"] = clean_folder_name(new_name)
                target_dir = os.path.join(self.master_folder, playlist_item["folder"])

            try:
                os.makedirs(target_dir, exist_ok=True)
                self._save_config()
                self._render_library_cards()
            except Exception as e:
                self._post("item", ("✕", f"Cannot create {target_dir}", str(e)))
                return None

        return target_dir

    def _sync_single_playlist(self, playlist_item):
        if self.is_running:
            messagebox.showinfo("Busy", "A sync operation is already running!")
            return

        valid_dir = self._verify_folder_integrity(playlist_item)
        if not valid_dir:
            return

        self.active_tasks = [self._playlist_task(playlist_item)]
        self._start_sync()

    def _playlist_task(self, pl):
        return {"folder": pl["folder"], "urls": [pl["url"]],
                "source": sources.detect_source(pl["url"]), "playlist": True}

    def _download_songs(self, folder, urls):
        """Download songs picked in the search window into a playlist folder."""
        if self.is_running:
            return
        self.active_tasks = [{"folder": folder, "urls": list(urls), "source": sources.YOUTUBE, "playlist": False}]
        self._start_sync()

    def _sync_all_playlists(self):
        if self.is_running:
            messagebox.showinfo("Busy", "A sync operation is already running!")
            return
        if not self.playlists:
            messagebox.showinfo("Empty", "No playlists in your library to sync.")
            return

        tasks = []
        for pl in self.playlists:
            valid_dir = self._verify_folder_integrity(pl)
            if valid_dir:
                tasks.append(self._playlist_task(pl))

        self.active_tasks = tasks
        self._start_sync()

    def _start_sync(self):
        for w in self.feed_scroll.winfo_children():
            w.destroy()
        self.counts = {"done": 0, "skip": 0, "fail": 0}
        self._update_counters()
        self.btn_why.pack_forget()
        self.report = {"started": time.time(), "finished": None,
                       "playlists": [t["folder"] for t in self.active_tasks if t.get("playlist")],
                       "entries": []}
        self._current_playlist = ""
        self.is_running = True
        self._ring_label = "Starting…"
        self._set_progress(0.0)
        self._tick_ring()
        self.lbl_status.configure(text="Syncing", fg_color=COLOR_ACCENT)
        self.btn_sync_all.configure(state="disabled", text="Syncing…")
        threading.Thread(target=self._download_worker, daemon=True).start()

    def _update_counters(self):
        self.lbl_cnt_done.configure(text=str(self.counts["done"]))
        self.lbl_cnt_skip.configure(text=str(self.counts["skip"]))
        self.lbl_cnt_fail.configure(text=str(self.counts["fail"]))

    def _add_activity_card(self, icon, title, subtitle, path=""):
        if getattr(self, "_placeholder", None) is not None and self._placeholder.winfo_exists():
            self._placeholder.destroy()
        kind = {"✔": "done", "↷": "skip", "✕": "fail"}.get(icon)
        if kind:
            self.counts[kind] += 1
            self._update_counters()
            if self.report is not None and self.is_running:
                self.report["entries"].append({
                    "kind": kind, "group": sources.group_for(kind, subtitle), "title": title,
                    "detail": subtitle or "", "path": path or "", "playlist": self._current_playlist,
                })
        color = {"done": COLOR_ACCENT, "fail": COLOR_DANGER, "skip": COLOR_TEXT_FAINT}.get(kind, COLOR_TEXT_PRIMARY)

        if icon == "📁":  # start of a playlist: show a section header
            self._current_playlist = title.replace("Syncing: ", "")
            self._ring_label = self._current_playlist[:22]
            self._draw_ring()
            ctk.CTkLabel(self.feed_scroll, text=title.replace("Syncing: ", "").upper(), font=self._font(11, "bold"),
                         text_color=COLOR_TEXT_MUTED, anchor="w").pack(fill="x", padx=10, pady=(12, 4))
            self.feed_scroll._parent_canvas.yview_moveto(1.0)
            return

        card = ctk.CTkFrame(self.feed_scroll, fg_color=COLOR_SURFACE, corner_radius=8)
        card.pack(fill="x", padx=4, pady=3)
        ctk.CTkFrame(card, width=3, height=10, fg_color=color, corner_radius=2).pack(side="left", fill="y", padx=(6, 0), pady=8)
        box = ctk.CTkFrame(card, fg_color="transparent")
        box.pack(side="left", fill="both", expand=True, padx=10, pady=6)
        ctk.CTkLabel(box, text=title, font=self._font(12, "bold"), text_color=COLOR_TEXT_PRIMARY,
                     anchor="w", justify="left", wraplength=220).pack(fill="x")
        if subtitle:
            ctk.CTkLabel(box, text=subtitle, font=self._font(10), text_color=COLOR_TEXT_MUTED,
                         anchor="w", justify="left", wraplength=220).pack(fill="x")

        # Keep the feed light: long syncs can post hundreds of items.
        for w in self.feed_scroll.winfo_children()[:-150]:
            w.destroy()
        self.feed_scroll._parent_canvas.yview_moveto(1.0)

    def _handle_raw_log(self, text):
        # Songs are reported by sources.spotdl_listener (with reasons). The log
        # only tells us about Spotify tracks spotdl can't handle at all.
        if "Skipping track" in text and "local tracks" in text:
            m = re.search(r"Skipping track:\s*(\S+)", text)
            ident = m.group(1) if m and m.group(1) not in ("None", "") else "unknown"
            self._post("item", ("↷", "Local file or podcast episode",
                                f"Local file or podcast in the Spotify playlist (id {ident}): nothing to download"))

    def _poll_queue(self):
        try:
            while True:
                kind, value = self.msg_queue.get_nowait()
                if kind == "item":
                    self._add_activity_card(*value)
                elif kind == "status":
                    self.lbl_status.configure(text=value, fg_color=COLOR_ACCENT)
                elif kind == "progress":
                    self._set_progress(value)
                elif kind == "call":
                    value()
                elif kind == "phone":
                    stamp = time.strftime("%H:%M:%S")
                    self.phone_events.append(f"[{stamp}] {value}")
                    del self.phone_events[:-500]
                    if self.phone_dialog is not None and self.phone_dialog.winfo_exists():
                        self.phone_dialog.refresh()
                elif kind == "done":
                    self.is_running = False
                    self._ring_label = "Done"
                    self._set_progress(1.0)
                    self.lbl_status.configure(text="Done", fg_color=COLOR_CYAN)
                    self.btn_sync_all.configure(state="normal", text="Sync all")
                    if self.report is not None:
                        self.report["finished"] = time.time()
                        self._save_report()
                    if self.counts["fail"] or self.counts["skip"]:
                        self.btn_why.pack(fill="x", padx=18, pady=(0, 8), before=self.feed_scroll._parent_frame)
                    self._render_library_cards()
                    self._refresh_last_sync()
                    if self.report_window is not None and self.report_window.winfo_exists():
                        self.report_window.reload()
        except queue.Empty:
            pass
        self.after(100, self._poll_queue)

    def _post(self, kind, value=""):
        self.msg_queue.put((kind, value))

    def _on_close(self):
        if self.is_running:
            if not messagebox.askyesno("Exit Confirmation", "Syncing is in progress. Quit anyway?"):
                return
        self.destroy()
        os._exit(0)

    def _download_worker(self):
        # Any crash here used to kill the thread silently and leave the UI
        # stuck on "Syncing..." forever. Report it and unlock the UI instead.
        try:
            self._download_worker_inner()
        except Exception as e:
            self._post("item", ("✕", "Sync crashed", f"{type(e).__name__}: {e}"))
            self._post("done")

    def _download_worker_inner(self):
        real_signal = signal.signal

        def safe_signal(signum, handler):
            try:
                return real_signal(signum, handler)
            except ValueError:
                return None

        signal.signal = safe_signal
        try:
            self._run_tasks()
        finally:
            signal.signal = real_signal
            self._post("done")

    def _run_tasks(self):
        # Every source needs FFmpeg to convert audio. The exe ships its own
        # copy; a dev run falls back to the PC's copy or a one-time download.
        if not sources.bundled_ffmpeg():
            self._post("status", "FFmpeg")
            self._post("item", ("⬇", "Setting up FFmpeg", "One-time setup, 10-30 seconds"))
        ffmpeg_path = sources.ensure_ffmpeg()
        if not ffmpeg_path:
            self._post("item", ("✕", "FFmpeg not available", "Check your internet connection and try again"))
            return

        tasks = list(self.active_tasks)
        total = len(tasks)
        for i, task in enumerate(tasks, 1):
            folder_name = task["folder"]
            target_dir = os.path.join(self.master_folder, folder_name)
            os.makedirs(target_dir, exist_ok=True)

            self._post("progress", (i - 1) / total)
            self._post("status", f"{i}/{total}")
            self._post("item", ("📁", f"Syncing: {folder_name}", target_dir))

            try:
                if task["source"] == sources.SPOTIFY:
                    self._run_spotdl(task["urls"][0], target_dir, folder_name)
                elif task["source"] == sources.YOUTUBE and task.get("playlist"):
                    # Saved YouTube links: swap videos for clean copies of the songs.
                    sources.sync_youtube(task["urls"][0], target_dir, self._report, ffmpeg_path)
                else:
                    sources.download(task["urls"], target_dir, self._report, ffmpeg_path)
            except Exception as e:
                self._post("item", ("✕", f"Error on {folder_name}", f"{type(e).__name__}: {e}"))

            if task.get("playlist"):
                for pl in self.playlists:
                    if pl.get("folder") == folder_name:
                        pl["has_synced"] = True
            self._post("progress", i / total)

        self._save_config()

    def _report(self, kind, title, detail, path=""):
        icon = {"done": "✔", "skip": "↷", "fail": "✕"}[kind]
        self._post("item", (icon, title, detail, path))

    def _run_spotdl(self, url, target_dir, folder_name):
        try:
            from spotdl.console import console_entry_point
        except ImportError:
            from spotdl.__main__ import console_entry_point
        from spotdl.utils.spotify import SpotifyClient

        sources.apply_spotdl_clean_rules()
        sources.spotdl_failures.clear()
        sources.spotdl_listener = self._report
        SpotifyClient._instance = None
        spotdl_logger = logging.getLogger("spotdl")
        for h in list(spotdl_logger.handlers):
            spotdl_logger.removeHandler(h)

        orig_cwd = os.getcwd()
        orig_argv = sys.argv
        old_stdout, old_stderr = sys.stdout, sys.stderr
        stream = LogStream(self._handle_raw_log)

        try:
            os.chdir(target_dir)
            sys.argv = [
                "spotdl",
                "download",
                url,
                # Clean-music order; spotdl's match check stays on so a wrong
                # or long video version falls through to the next source.
                "--audio", *sources.SPOTDL_AUDIO_ORDER,
                "--threads", "8",
                "--format", "m4a",
                "--simple-tui"
            ]
            sys.stdout = stream
            sys.stderr = stream
            console_entry_point()
        except SystemExit:
            pass
        finally:
            try:
                stream.flush()
            except Exception:
                pass
            sys.stdout = old_stdout
            sys.stderr = old_stderr
            sys.argv = orig_argv
            os.chdir(orig_cwd)
            sources.spotdl_listener = None
            sources.spotdl_failures.clear()


# -------------------------------------------------------------
# Sync report: every failed and skipped song, and why
# -------------------------------------------------------------
REPORT_ROW_LIMIT = 300


def search_query_for(title):
    """Search words for a song title from a report ("Artist - Song (From "X")")."""
    t = re.sub(r"\(\s*from[^)]*\)", "", title or "", flags=re.I)
    t = re.sub(r"[\[\(][^\]\)]*[\]\)]", "", t)
    return " ".join(t.replace(" - ", " ").split())


class SyncReportWindow(ctk.CTkToplevel):
    TABS = (("fail", "failed", COLOR_DANGER), ("skip", "skipped", COLOR_SKIP), ("done", "downloaded", COLOR_CYAN))

    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title("Sync report")
        self.geometry("1120x720")
        self.minsize(900, 560)
        self.configure(fg_color=COLOR_BG)
        self.transient(app)
        icon_path = get_resource_path("app_icon.ico")
        if os.path.exists(icon_path):
            self.after(200, lambda: self.iconbitmap(icon_path))

        self.tab = "fail"
        self.group = None

        head = ctk.CTkFrame(self, fg_color="transparent")
        head.pack(fill="x", padx=28, pady=(22, 0))
        box = ctk.CTkFrame(head, fg_color="transparent")
        box.pack(side="left", fill="x", expand=True)
        self.lbl_sub = ctk.CTkLabel(box, text="", font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED, anchor="w")
        self.lbl_sub.pack(fill="x")
        ctk.CTkLabel(box, text="Sync report", font=ctk.CTkFont(family=DISPLAY_FONT, size=28, weight="bold"),
                     text_color=COLOR_TEXT_PRIMARY, anchor="w").pack(fill="x")
        for text, cmd in (("Save as text", self._save_text), ("Copy list", self._copy)):
            ctk.CTkButton(head, text=text, height=40, width=120, corner_radius=20, fg_color=COLOR_SURFACE,
                          hover_color=COLOR_CARD_HOVER, border_width=1, border_color=COLOR_BORDER,
                          text_color=COLOR_TEXT_PRIMARY, font=ctk.CTkFont(size=13, weight="bold"),
                          command=cmd).pack(side="right", padx=(10, 0))

        # Share of downloaded / skipped / failed
        self.bar = ctk.CTkFrame(self, height=12, corner_radius=6, fg_color=COLOR_CARD)
        self.bar.pack(fill="x", padx=28, pady=(16, 0))
        self.bar_parts = {k: ctk.CTkFrame(self.bar, height=12, corner_radius=0, fg_color=c) for k, _, c in
                          (("done", "", COLOR_CYAN), ("skip", "", COLOR_SKIP), ("fail", "", COLOR_DANGER))}

        self.tabs_row = ctk.CTkFrame(self, fg_color="transparent")
        self.tabs_row.pack(fill="x", padx=28, pady=(14, 0))
        self.tab_buttons = {}
        for kind, label, _ in self.TABS:
            b = ctk.CTkButton(self.tabs_row, text="", height=58, width=190, corner_radius=18, anchor="w",
                              border_width=1, font=ctk.CTkFont(size=15, weight="bold"),
                              command=lambda k=kind: self._select_tab(k))
            b.pack(side="left", padx=(0, 10))
            self.tab_buttons[kind] = b

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.pack(fill="both", expand=True, padx=28, pady=(14, 22))
        left = ctk.CTkFrame(body, fg_color="transparent", width=360)
        left.pack(side="left", fill="y")
        left.pack_propagate(False)
        ctk.CTkLabel(left, text="WHY", font=ctk.CTkFont(size=11, weight="bold"), text_color=COLOR_TEXT_MUTED,
                     anchor="w").pack(fill="x", pady=(0, 6))
        self.groups_box = ctk.CTkScrollableFrame(left, fg_color="transparent", corner_radius=0)
        self.groups_box.pack(fill="both", expand=True)

        right = ctk.CTkFrame(body, fg_color=COLOR_SURFACE, corner_radius=20, border_width=1, border_color=COLOR_BORDER)
        right.pack(side="left", fill="both", expand=True, padx=(16, 0))
        rhead = ctk.CTkFrame(right, fg_color="transparent")
        rhead.pack(fill="x", padx=18, pady=(14, 8))
        rbox = ctk.CTkFrame(rhead, fg_color="transparent")
        rbox.pack(side="left", fill="x", expand=True)
        self.lbl_group = ctk.CTkLabel(rbox, text="", font=ctk.CTkFont(family=DISPLAY_FONT, size=19, weight="bold"),
                                      text_color=COLOR_TEXT_PRIMARY, anchor="w")
        self.lbl_group.pack(fill="x")
        self.lbl_group_sub = ctk.CTkLabel(rbox, text="", font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED,
                                          anchor="w", justify="left", wraplength=520)
        self.lbl_group_sub.pack(fill="x")
        self.btn_group = ctk.CTkButton(rhead, text="", height=40, corner_radius=20, fg_color=COLOR_ACCENT,
                                       hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT,
                                       font=ctk.CTkFont(size=13, weight="bold"))
        self.rows = ctk.CTkScrollableFrame(right, fg_color="transparent", corner_radius=0)
        self.rows.pack(fill="both", expand=True, padx=6, pady=(0, 10))

        self.reload()

    # ------------------------------------------------------------ data
    def reload(self):
        rep = self.app.report or {"entries": []}
        self.entries = rep.get("entries", [])
        counts = self.app._report_counts()
        names = rep.get("playlists") or []
        finished = rep.get("finished") or rep.get("started")
        when = time.strftime("%d %b %Y, %H:%M", time.localtime(finished)) if finished else "no sync yet"
        what = ", ".join(names[:3]) + (f" and {len(names) - 3} more" if len(names) > 3 else "") if names else "Last sync"
        total = sum(counts.values())
        self.lbl_sub.configure(text=f"{what} · {when} · {total} songs checked")

        x = 0.0
        for kind in ("done", "skip", "fail"):
            share = counts[kind] / total if total else 0
            part = self.bar_parts[kind]
            if share > 0:
                part.place(relx=x, rely=0, relwidth=max(share, 0.004), relheight=1)
            else:
                part.place_forget()
            x += share

        for kind, label, color in self.TABS:
            self.tab_buttons[kind].configure(text=f"  {counts[kind]}   {label}")
        if self.tab == "fail" and not counts["fail"]:
            self.tab = "skip" if counts["skip"] else "done"
        self._select_tab(self.tab, keep_group=True)

    def _groups(self, kind):
        found = {}
        for e in self.entries:
            if e.get("kind") == kind:
                found.setdefault(e.get("group") or "other", []).append(e)
        order = list(sources.REASONS.get(kind, {}).keys())
        return sorted(found.items(), key=lambda kv: (-len(kv[1]), order.index(kv[0]) if kv[0] in order else 99))

    # ------------------------------------------------------------ tabs and groups
    def _select_tab(self, kind, keep_group=False):
        self.tab = kind
        for k, b in self.tab_buttons.items():
            on = k == kind
            b.configure(fg_color=COLOR_HERO if on else COLOR_SURFACE, hover_color=COLOR_CARD_HOVER,
                        border_color=COLOR_ACCENT if on else COLOR_BORDER, text_color=COLOR_TEXT_PRIMARY)
        groups = self._groups(kind)
        ids = [g for g, _ in groups]
        if not keep_group or self.group not in ids:
            self.group = ids[0] if ids else None

        for w in self.groups_box.winfo_children():
            w.destroy()
        if not groups:
            ctk.CTkLabel(self.groups_box, text={"fail": "Nothing failed.",
                                                "skip": "Nothing was skipped.",
                                                "done": "Nothing was downloaded in this sync."}[kind],
                         font=ctk.CTkFont(size=13), text_color=COLOR_TEXT_MUTED).pack(anchor="w", pady=10)
        for gid, items in groups:
            title, why, fix = sources.REASONS.get(kind, {}).get(gid, ("Other", "", ""))
            on = gid == self.group
            card = ctk.CTkFrame(self.groups_box, fg_color=COLOR_HERO if on else COLOR_SURFACE, corner_radius=18,
                                border_width=1, border_color=COLOR_ACCENT if on else COLOR_BORDER)
            card.pack(fill="x", pady=(0, 10), padx=(0, 6))
            top = ctk.CTkFrame(card, fg_color="transparent")
            top.pack(fill="x", padx=14, pady=(12, 2))
            ctk.CTkLabel(top, text=title, font=ctk.CTkFont(size=14, weight="bold"), text_color=COLOR_TEXT_PRIMARY,
                         anchor="w").pack(side="left")
            ctk.CTkLabel(top, text=str(len(items)), width=34, height=22, corner_radius=11,
                         fg_color=COLOR_DANGER_SOFT if kind == "fail" else COLOR_CARD,
                         text_color=COLOR_DANGER if kind == "fail" else COLOR_TEXT_PRIMARY,
                         font=ctk.CTkFont(size=12, weight="bold")).pack(side="right")
            if why:
                ctk.CTkLabel(card, text=why, font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED, anchor="w",
                             justify="left", wraplength=300).pack(fill="x", padx=14)
            if fix:
                ctk.CTkLabel(card, text=fix, font=ctk.CTkFont(size=12, weight="bold"), text_color=COLOR_ACCENT_TEXT,
                             anchor="w", justify="left", wraplength=300).pack(fill="x", padx=14, pady=(4, 0))
            ctk.CTkFrame(card, height=10, fg_color="transparent").pack()
            for w in [card, top] + list(card.winfo_children()) + list(top.winfo_children()):
                w.bind("<Button-1>", lambda e, g=gid: self._select_group(g))
                try:
                    w.configure(cursor="hand2")
                except Exception:
                    pass
        self._show_group()

    def _select_group(self, gid):
        self.group = gid
        self._select_tab(self.tab, keep_group=True)

    def _show_group(self):
        for w in self.rows.winfo_children():
            w.destroy()
        self.btn_group.pack_forget()
        items = [e for e in self.entries if e.get("kind") == self.tab and (e.get("group") or "other") == self.group]
        if not self.group:
            self.lbl_group.configure(text="")
            self.lbl_group_sub.configure(text="")
            return
        title, why, fix = sources.REASONS.get(self.tab, {}).get(self.group, ("Other", "", ""))
        self.lbl_group.configure(text=title)
        playlists = sorted({e.get("playlist", "") for e in items if e.get("playlist")})
        self.lbl_group_sub.configure(text=f"{len(items)} song{'' if len(items) == 1 else 's'}" + (f" · {', '.join(playlists[:3])}" if playlists else ""))

        if self.tab == "fail" and self.group in ("refused", "other") and playlists:
            self.btn_group.configure(text=f"Retry {len(items)} songs",
                                     command=lambda p=playlists: self._retry(p))
            self.btn_group.pack(side="right")

        for e in items[:REPORT_ROW_LIMIT]:
            self._row(e)
        if len(items) > REPORT_ROW_LIMIT:
            ctk.CTkLabel(self.rows, text=f"…and {len(items) - REPORT_ROW_LIMIT} more. Use Save as text for the full list.",
                         font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED).pack(pady=10)

    def _row(self, e):
        row = ctk.CTkFrame(self.rows, fg_color="transparent")
        row.pack(fill="x", padx=8, pady=2)
        color = {"fail": COLOR_DANGER, "skip": COLOR_SKIP, "done": COLOR_CYAN}[e["kind"]]
        ctk.CTkFrame(row, width=8, height=8, corner_radius=4, fg_color=color).pack(side="left", padx=(4, 12))
        text = ctk.CTkFrame(row, fg_color="transparent")
        text.pack(side="left", fill="x", expand=True, pady=6)
        ctk.CTkLabel(text, text=e.get("title", ""), font=ctk.CTkFont(size=13, weight="bold"),
                     text_color=COLOR_TEXT_PRIMARY, anchor="w", justify="left", wraplength=480).pack(fill="x")
        detail = e.get("detail", "")
        if e.get("playlist"):
            detail = f"{detail} · {e['playlist']}" if detail else e["playlist"]
        ctk.CTkLabel(text, text=detail, font=ctk.CTkFont(size=11), text_color=COLOR_TEXT_MUTED, anchor="w",
                     justify="left", wraplength=480).pack(fill="x")

        action = None
        if e["kind"] == "fail" and e.get("group") in ("no_clean", "unavailable", "other"):
            action = ("Find a version", lambda: self.app._open_search_dialog(search_query_for(e.get("title")), e.get("playlist", "")))
        elif e["kind"] == "fail":
            action = ("Retry", lambda: self._retry([e.get("playlist", "")]))
        elif e.get("path") and os.path.exists(e["path"]):
            action = ("Show file", lambda: self._show_file(e["path"]))
        if action:
            ctk.CTkButton(row, text=action[0], height=32, width=110, corner_radius=16, fg_color="transparent",
                          hover_color=COLOR_CARD_HOVER, border_width=1, border_color=COLOR_BORDER,
                          text_color=COLOR_TEXT_PRIMARY, font=ctk.CTkFont(size=12, weight="bold"),
                          command=action[1]).pack(side="right", padx=(8, 4))
        ctk.CTkFrame(self.rows, height=1, fg_color=COLOR_BORDER).pack(fill="x", padx=12)

    # ------------------------------------------------------------ actions
    def _retry(self, playlists):
        playlists = [p for p in playlists if p]
        if not playlists:
            messagebox.showinfo("Retry", "These songs came from Search. Search for them again to retry.", parent=self)
            return
        self.app._retry_playlists(set(playlists))

    def _show_file(self, path):
        if os.name == "nt":
            subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
        else:
            subprocess.Popen(["xdg-open", os.path.dirname(path)])

    def report_text(self, kinds=("fail", "skip")):
        lines = [f"SpotVault sync report · {self.lbl_sub.cget('text')}", ""]
        for kind in kinds:
            label = {"fail": "FAILED", "skip": "SKIPPED", "done": "DOWNLOADED"}[kind]
            groups = self._groups(kind)
            lines.append(f"{label} ({sum(len(i) for _, i in groups)})")
            for gid, items in groups:
                title, why, fix = sources.REASONS.get(kind, {}).get(gid, ("Other", "", ""))
                lines.append(f"  {title} ({len(items)}): {why}".rstrip())
                if fix:
                    lines.append(f"    {fix}")
                for e in items:
                    where = f" [{e['playlist']}]" if e.get("playlist") else ""
                    lines.append(f"    - {e.get('title', '')}{where}: {e.get('detail', '')}")
            lines.append("")
        return "\n".join(lines)

    def _copy(self):
        self.clipboard_clear()
        self.clipboard_append(self.report_text())
        messagebox.showinfo("Copied", "The failed and skipped songs, with reasons, are on the clipboard.", parent=self)

    def _save_text(self):
        path = filedialog.asksaveasfilename(parent=self, defaultextension=".txt", initialfile="SpotVault sync report.txt",
                                            filetypes=[("Text file", "*.txt")])
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(self.report_text(("fail", "skip", "done")))
        except OSError as e:
            messagebox.showerror("Couldn't save", str(e), parent=self)


# -------------------------------------------------------------
# Update available
# -------------------------------------------------------------
class UpdateDialog(ctk.CTkToplevel):
    def __init__(self, parent, info):
        super().__init__(parent)
        self.app = parent
        self.info = info
        self._cancel = False
        self.title("Update available")
        self.geometry("520x460")
        self.resizable(False, False)
        self.configure(fg_color=COLOR_SURFACE)
        self.transient(parent)
        self.protocol("WM_DELETE_WINDOW", self._close)

        icon_path = get_resource_path("app_icon.ico")
        if os.path.exists(icon_path):
            self.after(200, lambda: self.iconbitmap(icon_path))

        ctk.CTkLabel(self, text=f"SpotVault {info['version']} is available",
                     font=ctk.CTkFont(size=18, weight="bold"), text_color=COLOR_TEXT_PRIMARY).pack(anchor="w", padx=24, pady=(22, 2))
        ctk.CTkLabel(self, text=f"You have v{APP_VERSION}. Your playlists, settings and music are kept.",
                     font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=24, pady=(0, 10))

        ctk.CTkLabel(self, text="WHAT'S NEW", font=ctk.CTkFont(size=11, weight="bold"),
                     text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=24)
        notes = ctk.CTkTextbox(self, height=200, fg_color=COLOR_SIDEBAR, border_width=1, border_color=COLOR_BORDER,
                               font=ctk.CTkFont(size=12), wrap="word")
        notes.pack(fill="both", expand=True, padx=24, pady=(4, 10))
        notes.insert("end", info["notes"] or "Improvements and fixes.")
        notes.configure(state="disabled")

        self.bar = ctk.CTkProgressBar(self, height=6, progress_color=COLOR_ACCENT, fg_color=COLOR_CARD)
        self.bar.set(0)
        self.lbl = ctk.CTkLabel(self, text="", font=ctk.CTkFont(size=11), text_color=COLOR_TEXT_MUTED)

        btns = ctk.CTkFrame(self, fg_color="transparent")
        btns.pack(fill="x", side="bottom", padx=24, pady=(0, 20))
        self.btn_skip = ctk.CTkButton(btns, text="Skip this version", width=130, height=38, corner_radius=19,
                                      fg_color="transparent", hover_color=COLOR_CARD, text_color=COLOR_TEXT_MUTED,
                                      command=self._skip)
        self.btn_skip.pack(side="left")
        self.btn_later = ctk.CTkButton(btns, text="Later", width=80, height=38, corner_radius=19,
                                       fg_color=COLOR_CARD, hover_color=COLOR_CARD_HOVER, command=self._close)
        self.btn_later.pack(side="left", padx=8)
        self.btn_go = ctk.CTkButton(btns, text="Update now", height=38, corner_radius=19, fg_color=COLOR_ACCENT,
                                    hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT,
                                    font=ctk.CTkFont(size=13, weight="bold"), command=self._update)
        self.btn_go.pack(side="right", fill="x", expand=True)

    def _skip(self):
        self.app.skip_update = self.info["version"]
        self.app._save_config()
        self._close()

    def _close(self):
        self._cancel = True
        self.destroy()

    def _update(self):
        if not self.info.get("installer"):
            webbrowser.open(self.info["page"])
            self._close()
            return
        if self.app.is_running and not messagebox.askyesno(
                "Download running", "A download is running. Stop it and update now?", parent=self):
            return
        for b in (self.btn_skip, self.btn_later, self.btn_go):
            b.configure(state="disabled")
        self.bar.pack(fill="x", padx=24, pady=(0, 4), before=self.btn_go.master)
        self.lbl.pack(anchor="w", padx=24, before=self.btn_go.master)
        self.lbl.configure(text="Downloading the update…")

        def progress(frac):
            self.app._post("call", lambda: self.winfo_exists() and self.bar.set(frac))

        def work():
            try:
                path, error = updater.download_installer(self.info, progress, lambda: self._cancel), None
            except Exception as e:
                path, error = None, e
            self.app._post("call", lambda: self._downloaded(path, error))

        threading.Thread(target=work, daemon=True).start()

    def _downloaded(self, path, error):
        if error is not None or not path:
            if self._cancel:
                return
            messagebox.showerror("Update failed",
                                 "The update couldn't be downloaded. You can also get it from the website.",
                                 parent=self)
            webbrowser.open(self.info["page"])
            self._close()
            return
        self.lbl.configure(text="Starting the installer…")
        try:
            # The installer replaces this exe, so SpotVault closes first.
            os.startfile(path)
        except OSError:
            webbrowser.open(self.info["page"])
            self._close()
            return
        self.app.after(800, lambda: (self.app.destroy(), os._exit(0)))


# -------------------------------------------------------------
# Song search (sources picked automatically)
# -------------------------------------------------------------
class SearchDialog(ctk.CTkToplevel):
    def __init__(self, parent, query="", folder=""):
        super().__init__(parent)
        self.app = parent
        self.title("Search songs")
        self.geometry("720x640")
        self.minsize(620, 480)
        self.configure(fg_color=COLOR_SURFACE)
        self.transient(parent)

        icon_path = get_resource_path("app_icon.ico")
        if os.path.exists(icon_path):
            self.after(200, lambda: self.iconbitmap(icon_path))

        self.results = []
        self.checks = []
        self._search_id = 0

        ctk.CTkLabel(self, text="Search songs", font=ctk.CTkFont(family=DISPLAY_FONT, size=24, weight="bold"),
                     text_color=COLOR_TEXT_PRIMARY).pack(anchor="w", padx=24, pady=(20, 2))
        ctk.CTkLabel(self, text="Find a song and save it into one of your playlists.",
                     font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=24, pady=(0, 12))

        bar = ctk.CTkFrame(self, fg_color="transparent")
        bar.pack(fill="x", padx=24)
        self.entry = ctk.CTkEntry(bar, placeholder_text="Song, artist or album", height=40,
                                  fg_color=COLOR_CARD, border_color=COLOR_BORDER, corner_radius=8)
        self.entry.pack(side="left", fill="x", expand=True)
        self.entry.bind("<Return>", lambda e: self._search())
        self.btn_search = ctk.CTkButton(bar, text="Search", width=90, height=40, corner_radius=20,
                                        fg_color=COLOR_ACCENT, hover_color=COLOR_ACCENT_HOVER,
                                        text_color=COLOR_ON_ACCENT, font=ctk.CTkFont(size=13, weight="bold"),
                                        command=self._search)
        self.btn_search.pack(side="left", padx=(10, 0))

        self.lbl_info = ctk.CTkLabel(self, text="", font=ctk.CTkFont(size=12), text_color=COLOR_TEXT_MUTED, anchor="w")
        self.lbl_info.pack(fill="x", padx=24, pady=(10, 4))

        self.list = ctk.CTkScrollableFrame(self, fg_color=COLOR_SIDEBAR, corner_radius=10)
        self.list.pack(fill="both", expand=True, padx=24)

        foot = ctk.CTkFrame(self, fg_color="transparent")
        foot.pack(fill="x", padx=24, pady=14)
        ctk.CTkLabel(foot, text="Save to", font=ctk.CTkFont(size=12, weight="bold"),
                     text_color=COLOR_TEXT_MUTED).pack(side="left")
        names = [pl["folder"] for pl in self.app.playlists]
        self.target = ctk.CTkOptionMenu(foot, values=names, height=36, fg_color=COLOR_CARD,
                                        button_color=COLOR_CARD_HOVER, button_hover_color=COLOR_ACCENT_HOVER,
                                        dropdown_fg_color=COLOR_CARD, dropdown_hover_color=COLOR_CARD_HOVER,
                                        text_color=COLOR_TEXT_PRIMARY, width=220, dynamic_resizing=False)
        self.target.set(folder if folder in names else names[0])
        self.target.pack(side="left", padx=(10, 0))
        self.btn_download = ctk.CTkButton(foot, text="Download selected", height=40, corner_radius=20,
                                          fg_color=COLOR_ACCENT, hover_color=COLOR_ACCENT_HOVER,
                                          text_color=COLOR_ON_ACCENT, font=ctk.CTkFont(size=13, weight="bold"),
                                          command=self._download)
        self.btn_download.pack(side="right")

        self.after(150, self.entry.focus)
        if query:
            self.entry.insert(0, query)
            self.lbl_info.configure(text="Pick the right version, then Download selected. It goes into the playlist "
                                         "the song failed in.", text_color=COLOR_TEXT_MUTED)
            self.after(300, self._search)

    def _search(self):
        query = self.entry.get().strip()
        if not query:
            return
        self._search_id += 1
        search_id = self._search_id
        self.btn_search.configure(state="disabled", text="…")
        self.lbl_info.configure(text="Searching…", text_color=COLOR_TEXT_MUTED)

        def work():
            try:
                results, error = sources.search_any(query), None
            except Exception as e:
                results, error = [], f"{type(e).__name__}: {e}"
            # Tk widgets may only be touched on the UI thread: hand the result
            # to the app's message queue, which runs it there.
            self.app._post("call", lambda: self._show(search_id, results, error))

        threading.Thread(target=work, daemon=True).start()

    def _show(self, search_id, results, error):
        if not self.winfo_exists() or search_id != self._search_id:
            return
        self.btn_search.configure(state="normal", text="Search")
        for w in self.list.winfo_children():
            w.destroy()
        self.results, self.checks = results, []
        if error:
            self.lbl_info.configure(text=f"Search failed. {error}"[:160], text_color=COLOR_DANGER)
            return
        if not results:
            self.lbl_info.configure(text="No songs found. Try other words.", text_color=COLOR_TEXT_MUTED)
            return
        self.lbl_info.configure(text=f"{len(results)} results. Tick the songs you want, then press Download selected.",
                                text_color=COLOR_TEXT_MUTED)
        COVER = 46
        covers = []
        for r in results:
            row = ctk.CTkFrame(self.list, fg_color=COLOR_SURFACE, corner_radius=8)
            row.pack(fill="x", padx=4, pady=3)
            var = ctk.BooleanVar(value=False)
            ctk.CTkCheckBox(row, text="", variable=var, width=24, fg_color=COLOR_ACCENT,
                            hover_color=COLOR_ACCENT_HOVER, border_color=COLOR_TEXT_FAINT).pack(side="left", padx=(10, 4), pady=8)
            art = ctk.CTkLabel(row, text="♪", width=COVER, height=COVER, fg_color=COLOR_CARD, corner_radius=6,
                               font=ctk.CTkFont(size=18), text_color=COLOR_TEXT_FAINT)
            art.pack(side="left", padx=(0, 10), pady=6)
            if r.get("thumb"):
                covers.append((art, r["thumb"]))
            ctk.CTkLabel(row, text=r["duration"], font=ctk.CTkFont(size=11),
                         text_color=COLOR_TEXT_MUTED).pack(side="right", padx=14)
            box = ctk.CTkFrame(row, fg_color="transparent")
            box.pack(side="left", fill="x", expand=True, pady=6)
            title = r["title"] if len(r["title"]) <= 58 else r["title"][:56].rstrip() + "…"
            ctk.CTkLabel(box, text=title, font=ctk.CTkFont(size=13, weight="bold"),
                         text_color=COLOR_TEXT_PRIMARY, anchor="w").pack(fill="x")
            ctk.CTkLabel(box, text=r["artist"], font=ctk.CTkFont(size=11),
                         text_color=COLOR_TEXT_MUTED, anchor="w").pack(fill="x")
            self.checks.append(var)
        self._load_covers(search_id, covers, COVER)

    def _load_covers(self, search_id, covers, size):
        """Fetch cover art in the background; the list shows at once and the
        pictures fill in. Wide video thumbnails are cropped to a square."""
        self._cover_images = []  # keep references, or Tk drops the pictures

        def fetch(url):
            res = requests.get(url, timeout=10, headers={"User-Agent": "SpotVault"})
            res.raise_for_status()
            pil = Image.open(io.BytesIO(res.content)).convert("RGB")
            w, h = pil.size
            side = min(w, h)
            pil = pil.crop(((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2))
            pil = pil.resize((size * 2, size * 2), Image.Resampling.LANCZOS)
            mask = Image.new("L", pil.size, 0)
            from PIL import ImageDraw
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, *pil.size), radius=12, fill=255)
            pil.putalpha(mask)
            return pil

        def apply(label, pil):
            if search_id != self._search_id or not label.winfo_exists():
                return
            img = ctk.CTkImage(light_image=pil, dark_image=pil, size=(size, size))
            self._cover_images.append(img)
            label.configure(image=img, text="", fg_color="transparent")

        def work():
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=6) as pool:
                futures = [(label, pool.submit(fetch, url)) for label, url in covers]
                for label, fut in futures:
                    if search_id != self._search_id:
                        return
                    try:
                        pil = fut.result()
                    except Exception:
                        continue  # keep the music-note placeholder
                    self.app._post("call", lambda l=label, p=pil: apply(l, p))

        threading.Thread(target=work, daemon=True).start()

    def _download(self):
        picked = [r["url"] for r, v in zip(self.results, self.checks) if v.get()]
        if not picked:
            messagebox.showinfo("Nothing selected", "Tick at least one song first.", parent=self)
            return
        if self.app.is_running:
            messagebox.showinfo("Busy", "A download is already running. Try again when it finishes.", parent=self)
            return
        folder = self.target.get()
        self.app._download_songs(folder, picked)
        for v in self.checks:
            v.set(False)
        self.lbl_info.configure(text=f"Downloading {len(picked)} song(s) into {folder}. Progress shows in Activity.",
                                text_color=COLOR_ACCENT_TEXT)


if __name__ == "__main__":
    multiprocessing.freeze_support()
    app = VaultApp()
    app.mainloop()