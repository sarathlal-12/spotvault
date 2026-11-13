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

APP_VERSION = "1.3"

# -------------------------------------------------------------
# Design tokens: "Midnight violet"
# -------------------------------------------------------------
COLOR_BG = "#0B0B14"          # Navy-black canvas
COLOR_SIDEBAR = "#08080F"     # Side panels
COLOR_SURFACE = "#14142A"     # Raised cards
COLOR_CARD = "#1C1C36"        # Inputs / feed items
COLOR_CARD_HOVER = "#26264A"
COLOR_ACCENT = "#8B5CF6"      # Violet
COLOR_ACCENT_HOVER = "#7C3AED"
COLOR_ON_ACCENT = "#FFFFFF"   # Text on accent buttons
COLOR_HERO = "#1A1636"        # Library header band
COLOR_HERO_TEXT = "#C9C2F2"
COLOR_TEXT_PRIMARY = "#F4F4FF"
COLOR_TEXT_MUTED = "#9A9AC0"
COLOR_TEXT_FAINT = "#5E5E85"
COLOR_BORDER = "#2A2A4A"
COLOR_DANGER = "#F43F5E"

ctk.set_appearance_mode("Dark")
ctk.set_default_color_theme("blue")

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
        self.lbl_addr = ctk.CTkLabel(info, text="", font=ctk.CTkFont(size=26, weight="bold"), text_color=COLOR_ACCENT, anchor="w", justify="left")
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
            self.lbl_state.configure(text="● Ready for phone sync", text_color=COLOR_ACCENT)
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

        self._load_config()
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
            except Exception:
                pass

    def _save_config(self):
        data = {
            "master_folder": self.master_folder,
            "playlists": self.playlists,
            "sync_pin": self.sync_pin,
            "skip_update": self.skip_update,
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

        # ---------- Sidebar ----------
        sidebar = ctk.CTkFrame(self, fg_color=COLOR_SIDEBAR, width=230, corner_radius=0)
        sidebar.pack(side="left", fill="y")
        sidebar.pack_propagate(False)

        brand = ctk.CTkFrame(sidebar, fg_color="transparent")
        brand.pack(fill="x", padx=20, pady=(24, 26))
        logo = ctk.CTkFrame(brand, width=34, height=34, corner_radius=17, fg_color=COLOR_ACCENT)
        logo.pack(side="left")
        logo.pack_propagate(False)
        ctk.CTkLabel(logo, text="♪", text_color=COLOR_ON_ACCENT, font=self._font(18, "bold")).place(relx=0.5, rely=0.5, anchor="center")
        ctk.CTkLabel(brand, text="SpotVault", font=self._font(21, "bold"), text_color=COLOR_TEXT_PRIMARY).pack(side="left", padx=(10, 0))

        # Library stats
        stats = ctk.CTkFrame(sidebar, fg_color=COLOR_SURFACE, corner_radius=10)
        stats.pack(fill="x", padx=14)
        ctk.CTkLabel(stats, text="YOUR LIBRARY", font=self._font(11, "bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14, pady=(12, 6))
        self.lbl_stat_playlists = self._stat_row(stats, "Playlists")
        self.lbl_stat_songs = self._stat_row(stats, "Songs")
        self.lbl_stat_size = self._stat_row(stats, "On disk", last=True)

        # Phone sync
        phone = ctk.CTkFrame(sidebar, fg_color=COLOR_SURFACE, corner_radius=10)
        phone.pack(fill="x", padx=14, pady=(12, 0))
        row = ctk.CTkFrame(phone, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(12, 2))
        ctk.CTkLabel(row, text="PHONE SYNC", font=self._font(11, "bold"), text_color=COLOR_TEXT_MUTED).pack(side="left")
        ok = self.phone_server.running
        ctk.CTkLabel(row, text="● Ready" if ok else "● Off", font=self._font(11, "bold"),
                     text_color=COLOR_ACCENT if ok else COLOR_DANGER).pack(side="right")
        ctk.CTkLabel(phone, text="Send playlists to the\nSpotVault phone app.", justify="left",
                     font=self._font(12), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14)
        ctk.CTkButton(
            phone, text="Connect phone", height=34, corner_radius=17,
            fg_color=COLOR_TEXT_PRIMARY, hover_color="#DCDCF0", text_color=COLOR_BG,
            font=self._font(13, "bold"), command=self._open_phone_dialog
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
        folder = ctk.CTkFrame(sidebar, fg_color=COLOR_SURFACE, corner_radius=10)
        folder.pack(side="bottom", fill="x", padx=14, pady=14)
        ctk.CTkLabel(folder, text="MUSIC FOLDER", font=self._font(11, "bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14, pady=(12, 2))
        self.lbl_master_path = ctk.CTkLabel(folder, text="", font=self._font(12), text_color=COLOR_TEXT_PRIMARY,
                                            anchor="w", justify="left", wraplength=180)
        self.lbl_master_path.pack(fill="x", padx=14)
        btns = ctk.CTkFrame(folder, fg_color="transparent")
        btns.pack(fill="x", padx=14, pady=(10, 14))
        ctk.CTkButton(btns, text="Open", height=30, width=80, corner_radius=15, fg_color=COLOR_CARD,
                      hover_color=COLOR_CARD_HOVER, font=self._font(12, "bold"),
                      command=self._open_master_folder).pack(side="left", expand=True, fill="x", padx=(0, 4))
        ctk.CTkButton(btns, text="Change", height=30, width=80, corner_radius=15, fg_color=COLOR_CARD,
                      hover_color=COLOR_CARD_HOVER, font=self._font(12, "bold"),
                      command=self._change_master_folder).pack(side="left", expand=True, fill="x", padx=(4, 0))

        # ---------- Activity panel (right) ----------
        self.right_pane = ctk.CTkFrame(self, width=300, fg_color=COLOR_SIDEBAR, corner_radius=0)
        self.right_pane.pack(side="right", fill="y")
        self.right_pane.pack_propagate(False)

        head = ctk.CTkFrame(self.right_pane, fg_color="transparent")
        head.pack(fill="x", padx=18, pady=(24, 10))
        ctk.CTkLabel(head, text="Activity", font=self._font(18, "bold"), text_color=COLOR_TEXT_PRIMARY).pack(side="left")
        self.lbl_status = ctk.CTkLabel(head, text="Idle", font=self._font(11, "bold"), text_color=COLOR_ON_ACCENT,
                                       fg_color=COLOR_CARD_HOVER, corner_radius=10, height=22, width=70)
        self.lbl_status.pack(side="right")

        self.progress_bar = ctk.CTkProgressBar(self.right_pane, height=6, corner_radius=3,
                                               progress_color=COLOR_ACCENT, fg_color=COLOR_CARD)
        self.progress_bar.pack(fill="x", padx=18)
        self.progress_bar.set(0)

        counters = ctk.CTkFrame(self.right_pane, fg_color="transparent")
        counters.pack(fill="x", padx=14, pady=(12, 8))
        self.lbl_cnt_done = self._counter(counters, "Downloaded", COLOR_ACCENT)
        self.lbl_cnt_skip = self._counter(counters, "Skipped", COLOR_TEXT_MUTED)
        self.lbl_cnt_fail = self._counter(counters, "Failed", COLOR_DANGER)

        self.feed_scroll = ctk.CTkScrollableFrame(self.right_pane, fg_color="transparent", corner_radius=0)
        self.feed_scroll.pack(fill="both", expand=True, padx=6, pady=(0, 10))
        self._feed_placeholder()

        # ---------- Main area ----------
        main = ctk.CTkFrame(self, fg_color=COLOR_BG, corner_radius=0)
        main.pack(side="left", fill="both", expand=True)

        hero = ctk.CTkFrame(main, fg_color=COLOR_HERO, corner_radius=0, height=150)
        hero.pack(fill="x")
        hero.pack_propagate(False)
        ctk.CTkLabel(hero, text="LIBRARY", font=self._font(11, "bold"), text_color=COLOR_HERO_TEXT).place(x=30, y=30)
        ctk.CTkLabel(hero, text="Your Playlists", font=self._font(34, "bold"), text_color=COLOR_TEXT_PRIMARY).place(x=28, y=48)
        self.lbl_hero_sub = ctk.CTkLabel(hero, text="", font=self._font(13), text_color=COLOR_HERO_TEXT)
        self.lbl_hero_sub.place(x=30, y=100)

        actions = ctk.CTkFrame(main, fg_color="transparent")
        actions.pack(fill="x", padx=28, pady=(18, 6))
        self.btn_sync_all = ctk.CTkButton(
            actions, text="⟳  Sync all", height=44, width=140, corner_radius=22,
            fg_color=COLOR_ACCENT, hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT,
            font=self._font(14, "bold"), command=self._sync_all_playlists
        )
        self.btn_sync_all.pack(side="left")
        ctk.CTkButton(
            actions, text="+  Add playlist", height=44, width=150, corner_radius=22,
            fg_color="transparent", hover_color=COLOR_CARD, border_width=1, border_color=COLOR_TEXT_FAINT,
            text_color=COLOR_TEXT_PRIMARY, font=self._font(14, "bold"), command=self._open_add_dialog
        ).pack(side="left", padx=12)
        ctk.CTkButton(
            actions, text="⌕  Search songs", height=44, width=160, corner_radius=22,
            fg_color="transparent", hover_color=COLOR_CARD, border_width=1, border_color=COLOR_TEXT_FAINT,
            text_color=COLOR_TEXT_PRIMARY, font=self._font(14, "bold"), command=self._open_search_dialog
        ).pack(side="left")

        self.cards_scroll = ctk.CTkScrollableFrame(main, fg_color="transparent", corner_radius=0)
        self.cards_scroll.pack(fill="both", expand=True, padx=16, pady=(6, 12))
        self.cards_scroll.bind("<Configure>", self._on_grid_resize)

        self._render_library_cards()

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
        cols = max(1, (event.width - 10) // 200)
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
        self.lbl_hero_sub.configure(text=f"{len(self.playlists)} playlists  •  {total_songs} songs downloaded")

        if not self.playlists:
            self._grid_cols = 0
            box = ctk.CTkFrame(self.cards_scroll, fg_color="transparent")
            box.pack(fill="both", expand=True, pady=70)
            ctk.CTkLabel(box, text="♪", font=self._font(54), text_color=COLOR_TEXT_FAINT).pack()
            ctk.CTkLabel(box, text="No playlists yet", font=self._font(20, "bold"), text_color=COLOR_TEXT_PRIMARY).pack(pady=(4, 4))
            ctk.CTkLabel(box, text="Paste a playlist link to start your offline library.",
                         font=self._font(13), text_color=COLOR_TEXT_MUTED).pack()
            ctk.CTkButton(box, text="+  Add playlist", height=40, corner_radius=20, fg_color=COLOR_ACCENT,
                          hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT, font=self._font(13, "bold"),
                          command=self._open_add_dialog).pack(pady=18)
            return

        width = self.cards_scroll.winfo_width()
        cols = max(1, (width - 10) // 200) if width > 1 else 3
        self._grid_cols = cols
        for c in range(cols):
            self.cards_scroll.grid_columnconfigure(c, weight=1, uniform="tile")

        for idx, pl in enumerate(self.playlists):
            count, size = stats[idx]
            tile = self._playlist_tile(idx, pl, count, size)
            tile.grid(row=idx // cols, column=idx % cols, padx=8, pady=8, sticky="nsew")

    def _playlist_tile(self, idx, pl, count, size):
        tile = ctk.CTkFrame(self.cards_scroll, fg_color=COLOR_SURFACE, corner_radius=10)
        cover = self._cover_image(pl.get("img_path", ""), 160)
        art = ctk.CTkLabel(tile, text="" if cover else "♪", image=cover, width=160, height=160,
                           fg_color="transparent" if cover else COLOR_CARD, corner_radius=8,
                           font=self._font(48), text_color=COLOR_TEXT_FAINT)
        art.pack(padx=14, pady=(14, 10))

        ctk.CTkLabel(tile, text=pl.get("title") or "Playlist", font=self._font(14, "bold"),
                     text_color=COLOR_TEXT_PRIMARY, anchor="w", wraplength=165, justify="left").pack(fill="x", padx=16)

        target = os.path.join(self.master_folder, pl.get("folder", ""))
        if pl.get("has_synced", False) and not os.path.exists(target):
            sub, color = "Folder missing", COLOR_DANGER
        elif not pl.get("has_synced", False):
            sub, color = "Not synced yet", COLOR_TEXT_MUTED
        else:
            sub, color = f"{count} songs  •  {size / 1024 / 1024:.0f} MB", COLOR_TEXT_MUTED
        ctk.CTkLabel(tile, text=sub, font=self._font(12), text_color=color, anchor="w").pack(fill="x", padx=16, pady=(2, 0))

        row = ctk.CTkFrame(tile, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(10, 14))
        ctk.CTkButton(row, text="Sync", height=32, width=80, corner_radius=16, fg_color=COLOR_ACCENT,
                      hover_color=COLOR_ACCENT_HOVER, text_color=COLOR_ON_ACCENT, font=self._font(12, "bold"),
                      command=lambda p=pl: self._sync_single_playlist(p)).pack(side="left")
        ctk.CTkButton(row, text="✕", height=32, width=32, corner_radius=16, fg_color=COLOR_CARD,
                      hover_color=COLOR_DANGER, font=self._font(12, "bold"),
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

    def _open_search_dialog(self):
        if not self.playlists:
            messagebox.showinfo("No playlists yet", "Add a playlist first. Search results are saved into one of your playlist folders.")
            return
        if self.search_dialog is not None and self.search_dialog.winfo_exists():
            self.search_dialog.focus()
            return
        self.search_dialog = SearchDialog(self)

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
        self.is_running = True
        self.progress_bar.set(0.0)
        self.lbl_status.configure(text="Syncing", fg_color=COLOR_ACCENT)
        self.btn_sync_all.configure(state="disabled", text="Syncing…")
        threading.Thread(target=self._download_worker, daemon=True).start()

    def _update_counters(self):
        self.lbl_cnt_done.configure(text=str(self.counts["done"]))
        self.lbl_cnt_skip.configure(text=str(self.counts["skip"]))
        self.lbl_cnt_fail.configure(text=str(self.counts["fail"]))

    def _add_activity_card(self, icon, title, subtitle):
        if getattr(self, "_placeholder", None) is not None and self._placeholder.winfo_exists():
            self._placeholder.destroy()
        kind = {"✔": "done", "↷": "skip", "✕": "fail"}.get(icon)
        if kind:
            self.counts[kind] += 1
            self._update_counters()
        color = {"done": COLOR_ACCENT, "fail": COLOR_DANGER, "skip": COLOR_TEXT_FAINT}.get(kind, COLOR_TEXT_PRIMARY)

        if icon == "📁":  # start of a playlist: show a section header
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
        if "Downloaded" in text:
            match = re.search(r'Downloaded\s+"([^"]+)"', text)
            if match:
                self._post("item", ("✔", match.group(1), "Saved (.m4a)"))
        elif "Skipping" in text or "already exists" in text:
            self._post("item", ("↷", text.replace("Skipping", "").strip(), "Already on disk"))
        elif "LookupError" in text or "AudioProviderError" in text:
            self._post("item", ("✕", text.split(":")[-1].strip(), "Provider match failed"))

    def _poll_queue(self):
        try:
            while True:
                kind, value = self.msg_queue.get_nowait()
                if kind == "item":
                    self._add_activity_card(value[0], value[1], value[2])
                elif kind == "status":
                    self.lbl_status.configure(text=value, fg_color=COLOR_ACCENT)
                elif kind == "progress":
                    self.progress_bar.set(value)
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
                    self.progress_bar.set(1.0)
                    self.lbl_status.configure(text="Done", fg_color=COLOR_ACCENT)
                    self.btn_sync_all.configure(state="normal", text="⟳  Sync all")
                    self._render_library_cards()
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

    def _report(self, kind, title, detail):
        icon = {"done": "✔", "skip": "↷", "fail": "✕"}[kind]
        self._post("item", (icon, title, detail))

    def _run_spotdl(self, url, target_dir, folder_name):
        try:
            from spotdl.console import console_entry_point
        except ImportError:
            from spotdl.__main__ import console_entry_point
        from spotdl.utils.spotify import SpotifyClient

        sources.apply_spotdl_clean_rules()
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
    def __init__(self, parent):
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

        ctk.CTkLabel(self, text="Search songs", font=ctk.CTkFont(size=18, weight="bold"),
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
        self.target.set(names[0])
        self.target.pack(side="left", padx=(10, 0))
        self.btn_download = ctk.CTkButton(foot, text="Download selected", height=40, corner_radius=20,
                                          fg_color=COLOR_ACCENT, hover_color=COLOR_ACCENT_HOVER,
                                          text_color=COLOR_ON_ACCENT, font=ctk.CTkFont(size=13, weight="bold"),
                                          command=self._download)
        self.btn_download.pack(side="right")

        self.after(150, self.entry.focus)

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
                                text_color=COLOR_ACCENT)


if __name__ == "__main__":
    multiprocessing.freeze_support()
    app = VaultApp()
    app.mainloop()