"""SpotVault engine: the PC downloader without a window.

The SpotVault 2.0 Windows app (Flutter) starts this program hidden and talks
to it over the same local web server the phones use (port 50505). Phones keep
using /api/... as before; the Windows app also uses /api/engine/..., which
only answers on this PC (127.0.0.1).

It does everything the 1.x window did: playlists, Sync all, the sync report,
phone sync, the Spotify key setting and update checks.
"""
import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time

import requests

# Same process setup as the 1.x app (hidden child consoles, PATH cleanup).
if os.name == "nt":
    _CREATE_NO_WINDOW = 0x08000000
    _orig_popen_init = subprocess.Popen.__init__

    def _hidden_popen_init(self, *args, **kwargs):
        kwargs["creationflags"] = kwargs.get("creationflags", 0) | _CREATE_NO_WINDOW
        _orig_popen_init(self, *args, **kwargs)

    subprocess.Popen.__init__ = _hidden_popen_init


def _drop_unreadable_path_entries():
    keep = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry:
            continue
        try:
            os.path.realpath(entry)
        except OSError:
            continue
        keep.append(entry)
    os.environ["PATH"] = os.pathsep.join(keep)


_drop_unreadable_path_entries()
os.environ.setdefault("COLUMNS", "160")

from phone_sync import PhoneSyncServer, generate_pin, get_lan_ips, HTTP_PORT  # noqa: E402
import sources  # noqa: E402
import updater  # noqa: E402

APP_VERSION = "2.3.0"
CONFIG_FILE = "library_config.json"
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".spot_sync_cache")
os.makedirs(CACHE_DIR, exist_ok=True)
REPORT_FILE = os.path.join(CACHE_DIR, "last_sync_report.json")


def _words(text):
    """Lower-case words of a song title, without brackets like (From "X") or [Official]."""
    text = re.sub(r"[\[(][^\])]*[\])]", " ", str(text).lower())
    return {w for w in re.findall(r"[\w']+", text) if len(w) > 1}
INVALID_NAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
FEED_KEEP = 400


def clean_folder_name(name):
    name = INVALID_NAME_CHARS.sub("", name or "").strip().rstrip(".")
    return name[:120]


def recycle(path):
    """Move a file or folder to the Windows Recycle Bin (so it can be restored)."""
    try:
        import ctypes
        from ctypes import wintypes

        class SHFILEOPSTRUCTW(ctypes.Structure):
            _fields_ = [("hwnd", wintypes.HWND), ("wFunc", wintypes.UINT), ("pFrom", wintypes.LPCWSTR),
                        ("pTo", wintypes.LPCWSTR), ("fFlags", ctypes.c_uint16), ("fAnyOperationsAborted", wintypes.BOOL),
                        ("hNameMappings", ctypes.c_void_p), ("lpszProgressTitle", wintypes.LPCWSTR)]

        FO_DELETE, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_SILENT, FOF_NOERRORUI = 3, 0x40, 0x10, 0x4, 0x400
        op = SHFILEOPSTRUCTW(None, FO_DELETE, os.path.abspath(path) + "\0", None,
                             FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI, False, None, None)
        return ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op)) == 0
    except Exception:
        return False


class _LogStream:
    """Collects spotdl's console output line by line."""

    def __init__(self, callback):
        self.callback = callback
        self.buf = ""

    def write(self, text):
        self.buf += str(text)
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            if line.strip():
                self.callback(line)
        return len(text)

    def flush(self):
        if self.buf.strip():
            self.callback(self.buf)
        self.buf = ""

    def isatty(self):
        return False

    def writable(self):
        return True


class Engine:
    def __init__(self):
        self.lock = threading.RLock()
        self.master_folder = os.path.join(os.path.expanduser("~"), "Music")
        self.playlists = []
        self.sync_pin = ""
        self.skip_update = ""
        self.spotify_id = ""
        self.spotify_secret = ""
        self.extra = {}  # settings only the 2.0 app reads (theme, name...)
        self._load_config()
        if not self.sync_pin:
            self.sync_pin = generate_pin()
            self._save_config()

        self.running = False
        self.stop_requested = False
        self.progress = 0.0
        self.status = "Ready"
        self.ring_label = ""
        self.current_playlist = ""
        self.counts = {"done": 0, "skip": 0, "fail": 0}
        self.feed = []          # [{seq, kind, title, detail, path, playlist, time}]
        self.seq = 0
        self.phone_events = []
        self.report = self._load_report()
        self.update_info = None
        self.update_progress = None
        self._tasks = []
        self._task_pos = (0, 1)
        self._songs_total = 0
        self._songs_seen = 0

        self.phone = PhoneSyncServer(
            get_state=lambda: (self.master_folder, list(self.playlists)),
            get_pin=lambda: self.sync_pin,
            on_event=self._phone_event,
        )
        self.phone.on_delete_playlist = self._delete_playlist_from_phone
        self.phone.engine = self
        self.version = APP_VERSION

    # ------------------------------------------------------------ config
    def _load_config(self):
        if not os.path.exists(CONFIG_FILE):
            return
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            return
        self.master_folder = data.get("master_folder", self.master_folder)
        self.playlists = data.get("playlists", [])
        self.sync_pin = str(data.get("sync_pin", ""))
        self.skip_update = str(data.get("skip_update", ""))
        self.spotify_id = str(data.get("spotify_client_id", ""))
        self.spotify_secret = str(data.get("spotify_client_secret", ""))
        self.extra = data.get("app2", {}) if isinstance(data.get("app2"), dict) else {}
        self.extra.setdefault("theme", data.get("theme", "dark"))

    def _save_config(self):
        with self.lock:
            data = {
                "master_folder": self.master_folder,
                "playlists": self.playlists,
                "sync_pin": self.sync_pin,
                "skip_update": self.skip_update,
                "theme": self.extra.get("theme", "dark"),
                "spotify_client_id": self.spotify_id,
                "spotify_client_secret": self.spotify_secret,
                "app2": self.extra,
            }
            try:
                tmp = CONFIG_FILE + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=4)
                os.replace(tmp, CONFIG_FILE)
            except OSError:
                pass

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

    # ------------------------------------------------------------ events
    def _phone_event(self, text):
        with self.lock:
            self.phone_events.append({"time": time.time(), "text": str(text)})
            del self.phone_events[:-300]

    def _event(self, kind, title, detail="", path=""):
        with self.lock:
            self.seq += 1
            e = {"seq": self.seq, "kind": kind, "title": title, "detail": detail or "",
                 "path": path or "", "playlist": self.current_playlist, "time": time.time()}
            self.feed.append(e)
            del self.feed[:-FEED_KEEP]
            if kind in self.counts:
                self.counts[kind] += 1
                if self.report is not None and self.running and getattr(self, "_manual", False):
                    if kind == "done":
                        self._tick_off(title, path)
                elif self.report is not None and self.running:
                    self.report["entries"].append({
                        "kind": kind, "group": sources.group_for(kind, detail), "title": title,
                        "detail": detail or "", "path": path or "", "playlist": self.current_playlist,
                    })

    def _tick_off(self, title, path=""):
        """Marks the failed/skipped report entry that a hand download just saved."""
        got = _words(title)
        best, score = None, 0.0
        for e in self.report.get("entries", []):
            if e.get("kind") not in ("fail", "skip") or e.get("playlist") != self.current_playlist:
                continue
            want = _words(e.get("title", ""))
            if not want:
                continue
            s = len(want & got) / len(want)
            if s > score:
                best, score = e, s
        if best is not None and score >= 0.6:
            best.update(kind="done", group="done", detail="Saved by hand", path=path or "")

    # ------------------------------------------------------------ library
    def folder_stats(self, folder):
        path = os.path.join(self.master_folder, folder)
        n = size = 0
        try:
            for entry in os.scandir(path):
                if entry.is_file() and os.path.splitext(entry.name)[1].lower() in (".m4a", ".mp3", ".opus", ".ogg", ".flac", ".wav", ".webm"):
                    n += 1
                    size += entry.stat().st_size
        except OSError:
            return {"songs": 0, "bytes": 0, "exists": False}
        return {"songs": n, "bytes": size, "exists": True}

    def add_playlist(self, url, folder=""):
        source, clean = sources.normalize_url(url)
        if not clean:
            return None, "That doesn't look like a Spotify, YouTube or SoundCloud playlist link."
        if any(p.get("url") == clean for p in self.playlists):
            return None, "That playlist is already in your library."
        try:
            meta = sources.fetch_metadata(source, clean)
        except Exception as e:
            return None, f"Couldn't read that playlist ({type(e).__name__}). Check the link and your internet."
        title = meta.get("title") or "Playlist"
        folder = clean_folder_name(folder or title) or "Playlist"
        base, n = folder, 2
        while any(p.get("folder") == folder for p in self.playlists):
            folder = f"{base} ({n})"
            n += 1
        try:
            os.makedirs(os.path.join(self.master_folder, folder), exist_ok=True)
        except OSError as e:
            return None, f"Couldn't create the folder: {e}"
        img = ""
        if meta.get("thumbnail_url"):
            try:
                res = requests.get(meta["thumbnail_url"], timeout=8)
                if res.status_code == 200:
                    img = os.path.join(CACHE_DIR, f"{folder}_{int(time.time())}.png")
                    with open(img, "wb") as f:
                        f.write(res.content)
            except Exception:
                img = ""
        item = {"url": clean, "folder": folder, "title": title, "img_path": img, "has_synced": False}
        with self.lock:
            self.playlists.append(item)
        self._save_config()
        return item, None

    def remove_playlist(self, folder, delete_files=False):
        with self.lock:
            before = len(self.playlists)
            self.playlists = [p for p in self.playlists if p.get("folder") != folder]
            changed = len(self.playlists) != before
        self._save_config()
        if delete_files and folder:
            path = os.path.join(self.master_folder, folder)
            master = os.path.realpath(self.master_folder)
            if os.path.isdir(path) and os.path.commonpath([os.path.realpath(path), master]) == master:
                recycle(path)
        return changed

    def rename_playlist(self, folder, title):
        with self.lock:
            for p in self.playlists:
                if p.get("folder") == folder:
                    p["title"] = title.strip()[:120] or p.get("title")
        self._save_config()

    def _delete_playlist_from_phone(self, folder):
        self.remove_playlist(folder, delete_files=True)

    # ------------------------------------------------------------ sync
    def _task_for(self, pl):
        return {"folder": pl["folder"], "urls": [pl["url"]], "source": sources.detect_source(pl["url"]), "playlist": True}

    def start_sync(self, folders=None):
        """folders: None for every playlist, else a list of folder names."""
        with self.lock:
            if self.running:
                return "A sync is already running."
            pls = [p for p in self.playlists if folders is None or p.get("folder") in folders]
            if not pls:
                return "No playlists to sync."
            tasks = [self._task_for(p) for p in pls]
        return self._start(tasks)

    def download_songs(self, folder, urls):
        with self.lock:
            if self.running:
                return "A sync is already running."
            if not any(p.get("folder") == folder for p in self.playlists):
                return "Pick one of your playlists."
            urls = [u for u in urls if u][:200]
            if not urls:
                return "Nothing to download."
        return self._start([{"folder": folder, "urls": urls, "source": sources.YOUTUBE, "playlist": False}])

    def import_lists(self, lists):
        """Song list import: {playlist name: ["Title - Artist", ...]}.

        Each playlist becomes a folder in the music folder; every song is found by
        name (clean-music search) and downloaded. Songs already there are skipped.
        """
        with self.lock:
            if self.running:
                return "A sync is already running."
        tasks = []
        for name, songs in list(lists.items())[:200]:
            folder = clean_folder_name(str(name)) or "Imported"
            names = [str(x).strip() for x in songs if str(x).strip()][:3000]
            if names:
                tasks.append({"folder": folder, "urls": [], "names": names, "source": sources.YOUTUBE, "playlist": False})
        if not tasks:
            return "There are no songs in that list."
        return self._start(tasks)

    def _download_names(self, names, target_dir, ffmpeg_path):
        """Find each "Title - Artist" online and download it, skipping songs already saved."""
        have = []
        try:
            have = [_words(os.path.splitext(e.name)[0]) for e in os.scandir(target_dir) if e.is_file()]
        except OSError:
            pass
        self._on_song_total(len(names))
        for name in names:
            if self.stop_requested:
                break
            want = _words(name)
            if want and any(len(want & h) / len(want) >= 0.8 for h in have):
                self._report("skip", name, "Already saved")
                continue
            try:
                url = sources.best_url_for(name)
            except Exception:
                self._report("fail", name, "Couldn't find this song online")
                continue
            before = self._songs_seen
            sources.download([url], target_dir, lambda kind, title, detail, path="": self._event(kind, title, detail, path), ffmpeg_path)
            self._songs_seen = before + 1
            self._song_progress()

    def _start(self, tasks):
        with self.lock:
            self._tasks = tasks
            self.running = True
            self.stop_requested = False
            self.counts = {"done": 0, "skip": 0, "fail": 0}
            self.progress = 0.0
            self.status = "Starting"
            self.ring_label = "Starting…"
            self.current_playlist = ""
            # A hand download (search -> download) keeps the last sync report, so the
            # songs that still failed stay listed; a song saved by hand is ticked off.
            self._manual = not any(t.get("playlist") or t.get("names") for t in tasks) and self.report is not None
            if not self._manual:
                self.report = {"started": time.time(), "finished": None,
                               "playlists": [t["folder"] for t in tasks if t.get("playlist")], "entries": []}
        threading.Thread(target=self._worker, daemon=True).start()
        return None

    def stop(self):
        with self.lock:
            if self.running:
                # Every download loop checks sources.stopped(), so the sync ends
                # within a song or two; songs already saved are kept.
                self.stop_requested = True
                self.status = "Stopping"

    def _worker(self):
        real_signal = signal.signal

        def safe_signal(signum, handler):
            try:
                return real_signal(signum, handler)
            except ValueError:
                return None

        signal.signal = safe_signal
        try:
            self._run_tasks()
        except Exception as e:
            self._event("fail", "Sync crashed", f"{type(e).__name__}: {e}")
        finally:
            signal.signal = real_signal
            with self.lock:
                self.running = False
                self.progress = 1.0
                self.status = "Stopped" if self.stop_requested else "Done"
                self.ring_label = "Done"
                if self.report is not None:
                    self.report["finished"] = time.time()
                    self._save_report()
            self._save_config()

    def _run_tasks(self):
        if not sources.bundled_ffmpeg():
            self.status = "Setting up FFmpeg"
            self._event("info", "Setting up FFmpeg", "One-time setup, 10-30 seconds")
        ffmpeg_path = sources.ensure_ffmpeg()
        if not ffmpeg_path:
            self._event("fail", "FFmpeg not available", "Check your internet connection and try again")
            return
        tasks = list(self._tasks)
        total = len(tasks)
        sources.total_listener = self._on_song_total
        sources.stop_check = lambda: self.stop_requested
        try:
            for i, task in enumerate(tasks, 1):
                if self.stop_requested:
                    break
                folder = task["folder"]
                target_dir = os.path.join(self.master_folder, folder)
                os.makedirs(target_dir, exist_ok=True)
                with self.lock:
                    self._task_pos = (i - 1, total)
                    self._songs_total = 0
                    self._songs_seen = 0
                    self.progress = (i - 1) / total
                    self.status = f"{i}/{total}" if total > 1 else "Syncing"
                    self.current_playlist = folder
                    self.ring_label = folder[:22]
                self._event("start", folder, target_dir)
                try:
                    if task.get("names"):
                        self._download_names(task["names"], target_dir, ffmpeg_path)
                    elif task["source"] == sources.SPOTIFY:
                        self._run_spotdl(task["urls"][0], target_dir)
                    elif task["source"] == sources.YOUTUBE and task.get("playlist"):
                        sources.sync_youtube(task["urls"][0], target_dir, self._report, ffmpeg_path)
                    else:
                        sources.download(task["urls"], target_dir, self._report, ffmpeg_path)
                except Exception as e:
                    self._event("fail", f"Error on {folder}", f"{type(e).__name__}: {e}")
                if task.get("playlist"):
                    with self.lock:
                        for pl in self.playlists:
                            if pl.get("folder") == folder:
                                pl["has_synced"] = True
                self.progress = i / total
        finally:
            sources.total_listener = None
            sources.stop_check = None

    def _report(self, kind, title, detail, path=""):
        self._event(kind, title, detail, path)
        self._songs_seen += 1
        self._song_progress()

    def _on_song_total(self, n):
        self._songs_total = max(int(n), 0)
        self._song_progress()

    def _song_progress(self):
        done, total = self._task_pos
        n, seen = self._songs_total, self._songs_seen
        if n:
            seen = min(seen, n)
            self.progress = (done + seen / n) / max(total, 1)
            self.ring_label = f"{seen} / {n} songs"

    def _raw_log(self, text):
        if "Skipping track" in text and "local tracks" in text:
            m = re.search(r"Skipping track:\s*(\S+)", text)
            ident = m.group(1) if m and m.group(1) not in ("None", "") else "unknown"
            self._event("skip", "Local file or podcast episode",
                        f"Local file or podcast in the Spotify playlist (id {ident}): nothing to download")

    def _run_spotdl(self, url, target_dir):
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

        orig_cwd, orig_argv = os.getcwd(), sys.argv
        old_stdout, old_stderr = sys.stdout, sys.stderr
        stream = _LogStream(self._raw_log)
        try:
            os.chdir(target_dir)
            sys.argv = ["spotdl", "download", url, "--audio", *sources.SPOTDL_AUDIO_ORDER, "--threads", "8",
                        "--format", "m4a", "--respect-skip-file", "--lyrics", "--simple-tui"]
            if self.spotify_id and self.spotify_secret:
                sys.argv += ["--client-id", self.spotify_id, "--client-secret", self.spotify_secret]
            sys.stdout = sys.stderr = stream
            console_entry_point()
        except SystemExit:
            pass
        finally:
            try:
                stream.flush()
            except Exception:
                pass
            sys.stdout, sys.stderr = old_stdout, old_stderr
            sys.argv = orig_argv
            os.chdir(orig_cwd)
            sources.spotdl_listener = None
            sources.spotdl_failures.clear()

    # ------------------------------------------------------------ updates
    def check_update(self):
        try:
            info = updater.check_latest()
        except Exception:
            return {"error": "Couldn't check for updates. Check your internet connection."}
        newer = bool(info) and updater.is_newer(info["version"], APP_VERSION)
        self.update_info = info if newer else None
        return {"current": APP_VERSION, "newer": newer, "info": info if newer else None,
                "skipped": bool(info) and info["version"] == self.skip_update}

    def install_update(self):
        info = self.update_info
        if not info or not info.get("installer"):
            return "No update to install."
        if self.update_progress is not None:
            return None

        def work():
            try:
                self.update_progress = 0.0
                path = updater.download_installer(info, progress=lambda p: setattr(self, "update_progress", p))
                self.update_progress = 1.0
                subprocess.Popen([path, "/SILENT", "/SP-", "/NOCANCEL"], close_fds=True)
            except Exception as e:
                self.update_progress = None
                self._phone_event(f"Update download failed: {e}")
        threading.Thread(target=work, daemon=True).start()
        return None

    # ------------------------------------------------------------ API
    def state(self, since=0):
        with self.lock:
            pls = []
            for p in self.playlists:
                st = self.folder_stats(p.get("folder", ""))
                pls.append({"folder": p.get("folder", ""), "title": p.get("title", ""), "url": p.get("url", ""),
                            "source": sources.detect_source(p.get("url", "")) or "",
                            "has_cover": bool(p.get("img_path") and os.path.isfile(p.get("img_path"))),
                            "has_synced": bool(p.get("has_synced")), **st})
            rep = self.report or {}
            rc = {"done": 0, "skip": 0, "fail": 0}
            for e in rep.get("entries", []):
                if e.get("kind") in rc:
                    rc[e["kind"]] += 1
            return {
                "version": APP_VERSION,
                "master_folder": self.master_folder,
                "playlists": pls,
                "sync": {"running": self.running, "progress": round(self.progress, 4), "status": self.status,
                         "label": self.ring_label, "playlist": self.current_playlist, "counts": dict(self.counts),
                         "stopping": self.stop_requested},
                "feed": [e for e in self.feed if e["seq"] > since][-200:],
                "seq": self.seq,
                "last_report": {"started": rep.get("started"), "finished": rep.get("finished"),
                                "playlists": rep.get("playlists") or [], "counts": rc} if rep else None,
                "phone": {"pin": self.sync_pin, "port": HTTP_PORT, "ips": get_lan_ips()[:3],
                          "running": self.phone.running, "error": self.phone.error,
                          "events": self.phone_events[-50:]},
                "spotify_key": bool(self.spotify_id and self.spotify_secret),
                "settings": dict(self.extra),
                "update_progress": self.update_progress,
            }

    def handle(self, method, route, query, body):
        """Routes under /api/engine/. Returns (status, json)."""
        r = route[len("/api/engine"):] or "/"
        data = {}
        if method == "POST":
            try:
                data = json.loads(body or b"{}")
            except ValueError:
                return 400, {"error": "Bad JSON"}
        if method == "GET" and r == "/state":
            try:
                since = int(query.get("since", ["0"])[0])
            except ValueError:
                since = 0
            return 200, self.state(since)
        if method == "GET" and r == "/report":
            return 200, self.report or {"entries": []}
        if method == "GET" and r == "/update":
            return 200, self.check_update()
        if method != "POST":
            return 404, {"error": "Not found"}
        if r == "/sync":
            folders = data.get("folders")
            err = self.start_sync(None if folders is None else [str(f) for f in folders])
            return (400, {"error": err}) if err else (200, {"ok": True})
        if r == "/stop":
            self.stop()
            return 200, {"ok": True}
        if r == "/download":
            err = self.download_songs(str(data.get("folder", "")), [str(u) for u in data.get("urls") or []])
            return (400, {"error": err}) if err else (200, {"ok": True})
        if r == "/import":
            lists = data.get("lists")
            if not isinstance(lists, dict):
                return 400, {"error": "Bad list"}
            err = self.import_lists({str(k): [str(x) for x in (v or [])] for k, v in lists.items() if isinstance(v, list)})
            return (400, {"error": err}) if err else (200, {"ok": True})
        if r == "/add":
            item, err = self.add_playlist(str(data.get("url", "")), str(data.get("folder", "")))
            return (400, {"error": err}) if err else (200, {"ok": True, "playlist": item})
        if r == "/remove":
            self.remove_playlist(str(data.get("folder", "")), bool(data.get("delete_files")))
            return 200, {"ok": True}
        if r == "/rename":
            self.rename_playlist(str(data.get("folder", "")), str(data.get("title", "")))
            return 200, {"ok": True}
        if r == "/settings":
            if "master_folder" in data and os.path.isdir(str(data["master_folder"])):
                self.master_folder = os.path.normpath(str(data["master_folder"]))
            if "spotify_id" in data or "spotify_secret" in data:
                cid, sec = str(data.get("spotify_id", "")).strip(), str(data.get("spotify_secret", "")).strip()
                if bool(cid) != bool(sec):
                    return 400, {"error": "Paste both the Client ID and the Client secret."}
                if cid and (not re.fullmatch(r"[0-9a-fA-F]{32}", cid) or not re.fullmatch(r"[0-9a-fA-F]{32}", sec)):
                    return 400, {"error": "Those don't look right: each is 32 letters and numbers."}
                self.spotify_id, self.spotify_secret = cid, sec
            if isinstance(data.get("app"), dict):
                self.extra.update({str(k): v for k, v in data["app"].items()})
            if "skip_update" in data:
                self.skip_update = str(data["skip_update"])
            self._save_config()
            return 200, {"ok": True}
        if r == "/new_pin":
            self.sync_pin = generate_pin()
            self._save_config()
            return 200, {"ok": True, "pin": self.sync_pin}
        if r == "/install_update":
            err = self.install_update()
            return (400, {"error": err}) if err else (200, {"ok": True})
        if r == "/open":
            target = str(data.get("path", "")) or self.master_folder
            if os.path.exists(target) and os.name == "nt":
                if os.path.isfile(target):
                    subprocess.Popen(["explorer", "/select,", os.path.normpath(target)])
                else:
                    os.startfile(target)
            return 200, {"ok": True}
        return 404, {"error": "Not found"}


def main():
    # Run from the install folder so library_config.json is the 1.x file.
    if getattr(sys, "frozen", False):
        os.chdir(os.path.dirname(os.path.dirname(sys.executable)) if os.path.basename(
            os.path.dirname(sys.executable)).lower() == "engine" else os.path.dirname(sys.executable))
    if "--mcp" in sys.argv:
        # AI assistants (MCP): charts, search, save songs; no engine server here.
        import mcp_server
        mcp_server.run()
        return
    engine = Engine()
    engine.phone.start()
    if not engine.phone.running:
        print(f"SpotVault engine could not start: {engine.phone.error}", flush=True)
        sys.exit(2)
    print(f"SpotVault engine {APP_VERSION} ready on {HTTP_PORT}", flush=True)
    parent = os.environ.get("SV_PARENT_PID")
    while True:
        time.sleep(2)
        # Quit with the Windows app, even mid-sync: songs already saved are kept,
        # and a running engine would block the next launch (port in use).
        if parent and not _pid_alive(int(parent)):
            engine.stop()
            os._exit(0)


def _pid_alive(pid):
    if os.name != "nt":
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    import ctypes
    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
    if not h:
        return False
    code = ctypes.c_ulong()
    ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
    ctypes.windll.kernel32.CloseHandle(h)
    return code.value == 259


if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()
    main()
