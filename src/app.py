import sys
import os
import io
import json
import logging
import re
import queue
import signal
import threading
import multiprocessing
import subprocess
import requests
from PIL import Image
from tkinter import filedialog, messagebox
import customtkinter as ctk

# Explicitly register Windows AppUserModelID so the taskbar displays our custom icon
if os.name == "nt":
    try:
        import ctypes
        app_id = "spotvault.musicdownloader.app.1.0"
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(app_id)
    except Exception:
        pass

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
# Main Application
# -------------------------------------------------------------
class SpotifyLibraryApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        self.title("SpotVault")
        self.geometry("980x720")
        self.minsize(850, 600)
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

        self._load_config()
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
            except Exception:
                pass

    def _save_config(self):
        data = {
            "master_folder": self.master_folder,
            "playlists": self.playlists
        }
        try:
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=4)
        except Exception:
            pass

    def _build_ui(self):
        # Top Header Bar
        header = ctk.CTkFrame(self, fg_color=COLOR_SURFACE, height=70, corner_radius=0)
        header.pack(fill="x", side="top")

        brand_box = ctk.CTkFrame(header, fg_color="transparent")
        brand_box.pack(side="left", padx=25, pady=15)

        ctk.CTkLabel(
            brand_box,
            text="●",
            font=ctk.CTkFont(size=28, weight="bold"),
            text_color=COLOR_ACCENT
        ).pack(side="left", padx=(0, 10))

        ctk.CTkLabel(
            brand_box,
            text="SpotVault",
            font=ctk.CTkFont(size=20, weight="bold"),
            text_color=COLOR_TEXT_PRIMARY
        ).pack(side="left")

        # Master Folder Selector
        path_box = ctk.CTkFrame(header, fg_color=COLOR_CARD, corner_radius=20, border_width=1, border_color=COLOR_BORDER)
        path_box.pack(side="right", padx=25, pady=15)

        self.lbl_master_path = ctk.CTkLabel(
            path_box,
            text=f"📁 {self.master_folder}",
            font=ctk.CTkFont(size=12),
            text_color=COLOR_TEXT_MUTED
        )
        self.lbl_master_path.pack(side="left", padx=(15, 10), pady=6)

        ctk.CTkButton(
            path_box,
            text="Change",
            width=70,
            height=26,
            corner_radius=13,
            fg_color=COLOR_SURFACE,
            hover_color=COLOR_CARD_HOVER,
            command=self._change_master_folder
        ).pack(side="right", padx=(0, 8), pady=4)

        # Main Layout Division
        self.body_panes = ctk.CTkFrame(self, fg_color="transparent")
        self.body_panes.pack(fill="both", expand=True, padx=25, pady=15)

        # Left: Playlists Deck
        self.left_pane = ctk.CTkFrame(self.body_panes, fg_color="transparent")
        self.left_pane.pack(side="left", fill="both", expand=True, padx=(0, 10))

        deck_actions = ctk.CTkFrame(self.left_pane, fg_color="transparent")
        deck_actions.pack(fill="x", pady=(0, 12))

        ctk.CTkLabel(
            deck_actions,
            text="Your Synced Playlists",
            font=ctk.CTkFont(size=18, weight="bold"),
            text_color=COLOR_TEXT_PRIMARY
        ).pack(side="left")

        ctk.CTkButton(
            deck_actions,
            text="+ Add Playlist",
            width=120,
            height=36,
            corner_radius=18,
            fg_color=COLOR_CARD,
            hover_color=COLOR_CARD_HOVER,
            font=ctk.CTkFont(weight="bold"),
            command=self._open_add_dialog
        ).pack(side="right", padx=(8, 0))

        self.btn_sync_all = ctk.CTkButton(
            deck_actions,
            text="⚡ Sync All Playlists",
            height=36,
            corner_radius=18,
            fg_color=COLOR_ACCENT,
            hover_color=COLOR_ACCENT_HOVER,
            text_color="#000000",
            font=ctk.CTkFont(weight="bold"),
            command=self._sync_all_playlists
        )
        self.btn_sync_all.pack(side="right")

        self.cards_scroll = ctk.CTkScrollableFrame(
            self.left_pane,
            fg_color=COLOR_SURFACE,
            corner_radius=12,
            border_width=1,
            border_color=COLOR_BORDER
        )
        self.cards_scroll.pack(fill="both", expand=True)

        # Right: Live Sync Hub
        self.right_pane = ctk.CTkFrame(
            self.body_panes,
            width=320,
            fg_color=COLOR_SURFACE,
            corner_radius=12,
            border_width=1,
            border_color=COLOR_BORDER
        )
        self.right_pane.pack(side="right", fill="both", padx=(10, 0))
        self.right_pane.pack_propagate(False)

        right_header = ctk.CTkFrame(self.right_pane, fg_color="transparent")
        right_header.pack(fill="x", padx=15, pady=(15, 8))

        ctk.CTkLabel(
            right_header,
            text="SYNC STATUS",
            font=ctk.CTkFont(size=12, weight="bold"),
            text_color=COLOR_TEXT_MUTED
        ).pack(side="left")

        self.lbl_status = ctk.CTkLabel(
            right_header,
            text="Idle",
            font=ctk.CTkFont(size=12, weight="bold"),
            text_color=COLOR_ACCENT
        )
        self.lbl_status.pack(side="right")

        self.progress_bar = ctk.CTkProgressBar(
            self.right_pane,
            height=8,
            corner_radius=4,
            progress_color=COLOR_ACCENT,
            fg_color=COLOR_CARD
        )
        self.progress_bar.pack(fill="x", padx=15, pady=(0, 10))
        self.progress_bar.set(0)

        self.feed_scroll = ctk.CTkScrollableFrame(
            self.right_pane,
            fg_color="#0D0D0D",
            corner_radius=8,
            border_width=1,
            border_color=COLOR_BORDER
        )
        self.feed_scroll.pack(fill="both", expand=True, padx=12, pady=(0, 12))

        self.btn_open_folder = ctk.CTkButton(
            self.right_pane,
            text="📁 Open Folder in Explorer",
            height=40,
            corner_radius=20,
            fg_color=COLOR_CARD,
            hover_color=COLOR_CARD_HOVER,
            font=ctk.CTkFont(weight="bold"),
            command=self._open_master_folder
        )
        self.btn_open_folder.pack(fill="x", padx=12, pady=(0, 12))

        self._render_library_cards()

    def _render_library_cards(self):
        """Draws all saved playlists as rich Spotify-styled cards."""
        for widget in self.cards_scroll.winfo_children():
            widget.destroy()

        if not self.playlists:
            placeholder = ctk.CTkFrame(self.cards_scroll, fg_color="transparent")
            placeholder.pack(fill="both", expand=True, pady=80)

            ctk.CTkLabel(
                placeholder,
                text="No Playlists Added Yet",
                font=ctk.CTkFont(size=18, weight="bold"),
                text_color=COLOR_TEXT_PRIMARY
            ).pack(pady=(0, 6))

            ctk.CTkLabel(
                placeholder,
                text="Click '+ Add Playlist' above to save your first Spotify playlist.",
                font=ctk.CTkFont(size=13),
                text_color=COLOR_TEXT_MUTED
            ).pack()
            return

        for idx, pl in enumerate(self.playlists):
            card = ctk.CTkFrame(
                self.cards_scroll,
                fg_color=COLOR_CARD,
                corner_radius=10,
                border_width=1,
                border_color=COLOR_BORDER
            )
            card.pack(fill="x", padx=10, pady=6)

            thumb_label = ctk.CTkLabel(card, text="♪", font=ctk.CTkFont(size=24), width=65, height=65)
            thumb_label.pack(side="left", padx=10, pady=10)

            img_path = pl.get("img_path", "")
            if img_path and os.path.exists(img_path):
                try:
                    pil_img = Image.open(img_path).resize((65, 65), Image.Resampling.LANCZOS)
                    ctk_img = ctk.CTkImage(light_image=pil_img, dark_image=pil_img, size=(65, 65))
                    thumb_label.configure(image=ctk_img, text="")
                except Exception:
                    pass

            info_frame = ctk.CTkFrame(card, fg_color="transparent")
            info_frame.pack(side="left", fill="both", expand=True, padx=10, pady=12)

            ctk.CTkLabel(
                info_frame,
                text=pl.get("title", "Spotify Playlist"),
                font=ctk.CTkFont(size=15, weight="bold"),
                text_color=COLOR_TEXT_PRIMARY,
                anchor="w"
            ).pack(fill="x")

            target_path = os.path.join(self.master_folder, pl.get("folder", ""))
            status_text = f"Folder: {pl.get('folder', '')}"
            status_color = COLOR_TEXT_MUTED

            # Warning only activates if it was synced before AND is now missing
            if pl.get("has_synced", False) and not os.path.exists(target_path):
                status_text += " [Missing / Deleted]"
                status_color = COLOR_DANGER

            ctk.CTkLabel(
                info_frame,
                text=status_text,
                font=ctk.CTkFont(size=12),
                text_color=status_color,
                anchor="w"
            ).pack(fill="x", pady=(2, 0))

            btn_box = ctk.CTkFrame(card, fg_color="transparent")
            btn_box.pack(side="right", padx=15, pady=10)

            ctk.CTkButton(
                btn_box,
                text="Sync",
                width=75,
                height=34,
                corner_radius=17,
                font=ctk.CTkFont(size=12, weight="bold"),
                fg_color=COLOR_ACCENT,
                hover_color=COLOR_ACCENT_HOVER,
                text_color="#000000",
                command=lambda p=pl: self._sync_single_playlist(p)
            ).pack(side="left", padx=(0, 6))

            ctk.CTkButton(
                btn_box,
                text="✕",
                width=34,
                height=34,
                corner_radius=17,
                fg_color=COLOR_SURFACE,
                hover_color=COLOR_DANGER,
                command=lambda idx=idx: self._remove_playlist(idx)
            ).pack(side="left")

    def _open_add_dialog(self):
        AddPlaylistDialog(self, self._handle_add_playlist)

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
            self.lbl_master_path.configure(text=f"📁 {self.master_folder}")
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
        self.is_running = True
        self.progress_bar.set(0.0)
        self.lbl_status.configure(text="Syncing...")
        self.btn_sync_all.configure(state="disabled")
        threading.Thread(target=self._download_worker, daemon=True).start()

    def _add_activity_card(self, icon, title, subtitle):
        card = ctk.CTkFrame(self.feed_scroll, fg_color=COLOR_CARD, corner_radius=6, height=38)
        card.pack(fill="x", padx=4, pady=2)

        badge_color = COLOR_TEXT_MUTED
        if icon == "✔":
            badge_color = COLOR_ACCENT
        elif icon == "✕":
            badge_color = COLOR_DANGER
        elif icon == "↷":
            badge_color = COLOR_TEXT_MUTED

        ctk.CTkLabel(
            card,
            text=icon,
            font=ctk.CTkFont(size=13, weight="bold"),
            text_color=badge_color,
            width=24
        ).pack(side="left", padx=(6, 2), pady=4)

        box = ctk.CTkFrame(card, fg_color="transparent")
        box.pack(side="left", fill="both", expand=True, padx=4, pady=2)

        ctk.CTkLabel(
            box,
            text=title,
            font=ctk.CTkFont(size=11, weight="bold"),
            text_color=COLOR_TEXT_PRIMARY,
            anchor="w"
        ).pack(fill="x")

        if subtitle:
            ctk.CTkLabel(
                box,
                text=subtitle,
                font=ctk.CTkFont(size=9),
                text_color=COLOR_TEXT_MUTED,
                anchor="w"
            ).pack(fill="x")

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
                    self.lbl_status.configure(text=value)
                elif kind == "progress":
                    self.progress_bar.set(value)
                elif kind == "done":
                    self.is_running = False
                    self.progress_bar.set(1.0)
                    self.lbl_status.configure(text="Finished")
                    self.btn_sync_all.configure(state="normal")
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