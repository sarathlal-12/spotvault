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

# Prevent Rich wrapping artifacts
os.environ.setdefault("COLUMNS", "160")

CONFIG_FILE = "library_config.json"
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".spot_sync_cache")
os.makedirs(CACHE_DIR, exist_ok=True)

# -------------------------------------------------------------
# Spotify Authentic Design Tokens
# -------------------------------------------------------------
COLOR_BG = "#121212"          # Spotify Pure Black Canvas
COLOR_SIDEBAR = "#000000"     # Pure Black Sidebar
COLOR_SURFACE = "#181818"     # Elevated Dark Grey Cards
COLOR_CARD = "#242424"        # Input Row / Feed Item Background
COLOR_CARD_HOVER = "#2A2A2A"
COLOR_ACCENT = "#1ED760"      # Spotify Brand Green
COLOR_ACCENT_HOVER = "#1DB954"
COLOR_TEXT_PRIMARY = "#FFFFFF"
COLOR_TEXT_MUTED = "#B3B3B3"
COLOR_BORDER = "#2E2E2E"
COLOR_DANGER = "#E91429"

ctk.set_appearance_mode("Dark")
ctk.set_default_color_theme("green")

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
INVALID_NAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
SPOTIFY_URL_RE = re.compile(
    r"^(https?://open\.spotify\.com/(intl-[a-zA-Z-]+/)?(playlist|album|track|artist)/[A-Za-z0-9]+"
    r"|spotify:(playlist|album|track|artist):[A-Za-z0-9]+)$"
)


def get_resource_path(relative_path):
    """Get absolute path to resource, works for dev and for PyInstaller."""
    try:
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(".")
    return os.path.join(base_path, relative_path)


def clean_url(url):
    return url.strip().split("?")[0].rstrip("/")


def clean_folder_name(name):
    name = INVALID_NAME_CHARS.sub("_", name.strip())
    return name.rstrip(" .")


def fetch_spotify_metadata(url):
    """Fetches playlist title and high-res cover art URL from Spotify's oEmbed API."""
    try:
        clean = clean_url(url)
        oembed_url = f"https://open.spotify.com/oembed?url={clean}"
        res = requests.get(oembed_url, timeout=5)
        if res.status_code == 200:
            data = res.json()
            return {
                "title": data.get("title", "Spotify Playlist"),
                "thumbnail_url": data.get("thumbnail_url", "")
            }
    except Exception:
        pass
    return {"title": "Spotify Playlist", "thumbnail_url": ""}


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
        ctk.CTkLabel(self, text="Spotify Playlist URL:", font=ctk.CTkFont(size=12, weight="bold"), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=30)
        self.entry_url = ctk.CTkEntry(
            self,
            placeholder_text="https://open.spotify.com/playlist/...",
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
            text_color="#000000",
            command=self._confirm
        ).pack(side="right", fill="x", expand=True, padx=(15, 0))

    def _confirm(self):
        url = clean_url(self.entry_url.get())
        folder = clean_folder_name(self.entry_folder.get())

        if not url or not folder:
            messagebox.showwarning("Missing Info", "Please fill in both the URL and the Folder Name.", parent=self)
            return
        if not SPOTIFY_URL_RE.match(url):
            messagebox.showwarning("Invalid URL", "Please enter a valid Spotify link.", parent=self)
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
        self.feed = ctk.CTkTextbox(self, height=150, fg_color="#0D0D0D", border_width=1, border_color=COLOR_BORDER, font=ctk.CTkFont(size=11))
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
class SpotifyLibraryApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        self.title("SpotVault")
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
        self.phone_events = []
        self.phone_dialog = None

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
        self.phone_server.start()

        self._build_ui()

        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(100, self._poll_queue)

    def _load_config(self):
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    self.master_folder = data.get("master_folder", self.master_folder)
                    self.playlists = data.get("playlists", [])
                    self.sync_pin = str(data.get("sync_pin", ""))
            except Exception:
                pass

    def _save_config(self):
        data = {
            "master_folder": self.master_folder,
            "playlists": self.playlists,
            "sync_pin": self.sync_pin
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
        ctk.CTkLabel(logo, text="♪", text_color="#000000", font=self._font(18, "bold")).place(relx=0.5, rely=0.5, anchor="center")
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
        ctk.CTkLabel(phone, text="Send playlists to the\nSpotVault Android app.", justify="left",
                     font=self._font(12), text_color=COLOR_TEXT_MUTED).pack(anchor="w", padx=14)
        ctk.CTkButton(
            phone, text="Connect phone", height=34, corner_radius=17,
            fg_color=COLOR_TEXT_PRIMARY, hover_color="#E0E0E0", text_color="#000000",
            font=self._font(13, "bold"), command=self._open_phone_dialog
        ).pack(fill="x", padx=14, pady=(10, 14))

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
        self.lbl_status = ctk.CTkLabel(head, text="Idle", font=self._font(11, "bold"), text_color="#000000",
                                       fg_color=COLOR_TEXT_MUTED, corner_radius=10, height=22, width=70)
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

        hero = ctk.CTkFrame(main, fg_color="#1F3D2B", corner_radius=0, height=150)
        hero.pack(fill="x")
        hero.pack_propagate(False)
        ctk.CTkLabel(hero, text="LIBRARY", font=self._font(11, "bold"), text_color="#CFEFDC").place(x=30, y=30)
        ctk.CTkLabel(hero, text="Your Playlists", font=self._font(34, "bold"), text_color=COLOR_TEXT_PRIMARY).place(x=28, y=48)
        self.lbl_hero_sub = ctk.CTkLabel(hero, text="", font=self._font(13), text_color="#CFEFDC")
        self.lbl_hero_sub.place(x=30, y=100)

        actions = ctk.CTkFrame(main, fg_color="transparent")
        actions.pack(fill="x", padx=28, pady=(18, 6))
        self.btn_sync_all = ctk.CTkButton(
            actions, text="⟳  Sync all", height=44, width=140, corner_radius=22,
            fg_color=COLOR_ACCENT, hover_color=COLOR_ACCENT_HOVER, text_color="#000000",
            font=self._font(14, "bold"), command=self._sync_all_playlists
        )
        self.btn_sync_all.pack(side="left")
        ctk.CTkButton(
            actions, text="+  Add playlist", height=44, width=150, corner_radius=22,
            fg_color="transparent", hover_color=COLOR_CARD, border_width=1, border_color="#727272",
            text_color=COLOR_TEXT_PRIMARY, font=self._font(14, "bold"), command=self._open_add_dialog
        ).pack(side="left", padx=12)

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
                     font=self._font(12), text_color="#6A6A6A", justify="center")
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
            ctk.CTkLabel(box, text="♪", font=self._font(54), text_color="#535353").pack()
            ctk.CTkLabel(box, text="No playlists yet", font=self._font(20, "bold"), text_color=COLOR_TEXT_PRIMARY).pack(pady=(4, 4))
            ctk.CTkLabel(box, text="Paste a Spotify playlist link to start your offline library.",
                         font=self._font(13), text_color=COLOR_TEXT_MUTED).pack()
            ctk.CTkButton(box, text="+  Add playlist", height=40, corner_radius=20, fg_color=COLOR_ACCENT,
                          hover_color=COLOR_ACCENT_HOVER, text_color="#000000", font=self._font(13, "bold"),
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
                           font=self._font(48), text_color="#535353")
        art.pack(padx=14, pady=(14, 10))

        ctk.CTkLabel(tile, text=pl.get("title", "Spotify Playlist"), font=self._font(14, "bold"),
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
                      hover_color=COLOR_ACCENT_HOVER, text_color="#000000", font=self._font(12, "bold"),
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

    def _handle_add_playlist(self, url, folder):
        meta = fetch_spotify_metadata(url)
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

        self.active_tasks = [(playlist_item["folder"], playlist_item["url"])]
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
                tasks.append((pl["folder"], pl["url"]))

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
        color = {"done": COLOR_ACCENT, "fail": COLOR_DANGER, "skip": "#6A6A6A"}.get(kind, "#FFFFFF")

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
                    self.lbl_status.configure(text=value.replace("Playlist ", ""), fg_color=COLOR_ACCENT)
                elif kind == "progress":
                    self.progress_bar.set(value)
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
        try:
            from spotdl.console import console_entry_point
        except ImportError:
            try:
                from spotdl.__main__ import console_entry_point
            except ImportError:
                self._post("item", ("✕", "SpotDL Not Found", "Install spotdl library"))
                self._post("done")
                return

        from spotdl.utils.spotify import SpotifyClient

        real_signal = signal.signal

        def safe_signal(signum, handler):
            try:
                return real_signal(signum, handler)
            except ValueError:
                return None

        signal.signal = safe_signal

        total = len(self.active_tasks)
        for i, (folder_name, url) in enumerate(self.active_tasks, 1):
            target_dir = os.path.join(self.master_folder, folder_name)
            os.makedirs(target_dir, exist_ok=True)

            self._post("progress", (i - 1) / total)
            self._post("status", f"Playlist {i}/{total}")
            self._post("item", ("📁", f"Syncing: {folder_name}", target_dir))

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
                    "--audio", "youtube-music", "youtube", "soundcloud",
                    "--dont-filter-results",
                    "--threads", "8",
                    "--format", "m4a",
                    "--simple-tui"
                ]
                sys.stdout = stream
                sys.stderr = stream
                console_entry_point()
            except SystemExit:
                pass
            except Exception as e:
                self._post("item", ("✕", f"Error on {folder_name}", str(e)))
            finally:
                try:
                    stream.flush()
                except Exception:
                    pass
                sys.stdout = old_stdout
                sys.stderr = old_stderr
                sys.argv = orig_argv
                os.chdir(orig_cwd)

            self._post("progress", i / total)

        # Mark all active playlists as successfully synced
        for folder_name, _ in self.active_tasks:
            for pl in self.playlists:
                if pl.get("folder") == folder_name:
                    pl["has_synced"] = True
        self._save_config()

        signal.signal = real_signal
        self._post("done")


if __name__ == "__main__":
    multiprocessing.freeze_support()
    app = SpotifyLibraryApp()
    app.mainloop()