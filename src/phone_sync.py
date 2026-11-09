"""Wi-Fi sync server for the SpotVault Android companion app.

The phone finds the PC with a UDP broadcast (or the user types the IP shown
in the "Phone Sync" window), then pulls the library over HTTP:

    GET /api/status                 public: app name, version, pin required
    GET /api/library                playlists + tracks (needs PIN)
    GET /api/file?path=<rel>        audio file, supports Range (needs PIN)
    GET /api/art?path=<rel>         embedded album art of a track (needs PIN)
    GET /api/cover?folder=<name>    playlist cover image (needs PIN)

Every protected request carries the PIN in the ``X-SpotVault-Pin`` header.
"""

import hashlib
import json
import os
import secrets
import socket
import socketserver
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_PORT = 50505
DISCOVERY_PORT = 50506
DISCOVERY_MAGIC = b"SPOTVAULT_DISCOVER_V1"
API_VERSION = 1
APP_VERSION = "1.1"

AUDIO_MIME = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
    ".flac": "audio/flac",
    ".wav": "audio/wav",
    ".ogg": "audio/ogg",
    ".opus": "audio/ogg",
}

CHUNK = 256 * 1024
MAX_FAILED_PINS = 10
LOCKOUT_SECONDS = 60


def generate_pin():
    return f"{secrets.randbelow(1_000_000):06d}"


def get_lan_ips():
    """Returns IPv4 addresses of this PC, the default-route one first."""
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # No packet is sent; this only asks the OS which interface it would use.
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return [ip for ip in ips if not ip.startswith("127.")]


# -------------------------------------------------------------
# Tag reading (mutagen ships with spotdl)
# -------------------------------------------------------------
_meta_cache = {}
_meta_lock = threading.Lock()


def _first(tags, key):
    try:
        val = tags.get(key)
        if isinstance(val, list):
            val = val[0] if val else None
        return str(val).strip() if val else ""
    except Exception:
        return ""


def read_track_meta(full_path, size, mtime):
    key = (full_path, size, mtime)
    with _meta_lock:
        if key in _meta_cache:
            return _meta_cache[key]

    stem = os.path.splitext(os.path.basename(full_path))[0]
    # spotdl names files "Artist - Title"
    if " - " in stem:
        artist, title = stem.split(" - ", 1)
    else:
        artist, title = "", stem
    meta = {"title": title, "artist": artist, "album": "", "duration": 0.0}

    try:
        import mutagen
        audio = mutagen.File(full_path, easy=True)
        if audio is not None:
            if audio.tags:
                meta["title"] = _first(audio.tags, "title") or meta["title"]
                meta["artist"] = _first(audio.tags, "artist") or meta["artist"]
                meta["album"] = _first(audio.tags, "album")
            if getattr(audio, "info", None) is not None:
                meta["duration"] = round(float(getattr(audio.info, "length", 0) or 0), 2)
    except Exception:
        pass

    with _meta_lock:
        _meta_cache[key] = meta
    return meta


def read_embedded_art(full_path):
    """Returns (bytes, mime) of the embedded cover, or (None, None)."""
    try:
        import mutagen
        audio = mutagen.File(full_path)
        if audio is None or audio.tags is None:
            return None, None
        tags = audio.tags
        # MP4 / M4A
        covr = tags.get("covr") if hasattr(tags, "get") else None
        if covr:
            img = covr[0]
            fmt = getattr(img, "imageformat", 13)
            return bytes(img), "image/png" if fmt == 14 else "image/jpeg"
        # MP3 (ID3 APIC)
        if hasattr(tags, "getall"):
            frames = tags.getall("APIC")
            if frames:
                return frames[0].data, frames[0].mime or "image/jpeg"
        # FLAC / OGG
        pictures = getattr(audio, "pictures", None)
        if pictures:
            return pictures[0].data, pictures[0].mime or "image/jpeg"
    except Exception:
        pass
    return None, None


# -------------------------------------------------------------
# HTTP handler
# -------------------------------------------------------------
class _Handler(BaseHTTPRequestHandler):
    server_version = "SpotVault"
    protocol_version = "HTTP/1.1"

    @property
    def sync(self):
        return self.server.sync

    def log_message(self, format, *args):
        pass

    # --- helpers -------------------------------------------------
    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, data, mime):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(data)

    def _error(self, code, msg):
        self._send_json(code, {"error": msg})

    def _authorized(self):
        ip = self.client_address[0]
        if self.sync.is_locked_out(ip):
            self._error(429, "Too many wrong PINs. Wait a minute.")
            return False
        given = self.headers.get("X-SpotVault-Pin", "")
        if secrets.compare_digest(given.encode(), self.sync.get_pin().encode()):
            self.sync.note_client(ip, self.headers.get("X-SpotVault-Device", "Phone"))
            return True
        self.sync.note_failed_pin(ip)
        self._error(401, "Wrong PIN")
        return False

    # --- routing -------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        route = parsed.path.rstrip("/")
        try:
            if route == "/api/status":
                return self._send_json(200, {
                    "app": "SpotVault",
                    "version": APP_VERSION,
                    "api": API_VERSION,
                    "name": socket.gethostname(),
                    "pin_required": True,
                })
            if not self._authorized():
                return
            if route == "/api/library":
                return self._send_json(200, self.sync.build_library())
            if route == "/api/file":
                return self._serve_file(query.get("path", [""])[0])
            if route == "/api/art":
                return self._serve_art(query.get("path", [""])[0])
            if route == "/api/cover":
                return self._serve_cover(query.get("folder", [""])[0])
            self._error(404, "Not found")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _serve_file(self, rel):
        full = self.sync.resolve_track(rel)
        if not full:
            return self._error(404, "Track not found")
        size = os.path.getsize(full)
        start, end = 0, size - 1
        status = 200

        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            try:
                a, b = rng[6:].split(",")[0].split("-")
                if a:
                    start = int(a)
                    end = int(b) if b else size - 1
                else:  # suffix range: last N bytes
                    start = max(0, size - int(b))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                end = min(end, size - 1)
                status = 206
            except ValueError:
                start, end, status = 0, size - 1, 200

        length = end - start + 1
        ext = os.path.splitext(full)[1].lower()
        self.send_response(status)
        self.send_header("Content-Type", AUDIO_MIME.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

        with open(full, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(CHUNK, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
        if start == 0 and remaining == 0:
            self.sync.note_sent(self.client_address[0], rel)

    def _serve_art(self, rel):
        full = self.sync.resolve_track(rel)
        if not full:
            return self._error(404, "Track not found")
        data, mime = read_embedded_art(full)
        if not data:
            return self._error(404, "No artwork")
        self._send_bytes(data, mime)

    def _serve_cover(self, folder):
        img_path = self.sync.cover_path(folder)
        if not img_path:
            return self._error(404, "No cover")
        with open(img_path, "rb") as f:
            data = f.read()
        mime = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
        self._send_bytes(data, mime)


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False  # never steal the port from another running copy

    def server_bind(self):
        # HTTPServer.server_bind calls socket.getfqdn(), which can stall for
        # seconds on Windows. The name is unused, so skip it.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


# -------------------------------------------------------------
# Public controller
# -------------------------------------------------------------
class PhoneSyncServer:
    """
    get_state(): returns (master_folder, playlists) where playlists is the app's
                 list of dicts with "folder", "title", "img_path".
    get_pin():   returns the current 6-digit PIN.
    on_event(text): optional, called from worker threads with activity text.
    """

    def __init__(self, get_state, get_pin, on_event=None):
        self._get_state = get_state
        self.get_pin = get_pin
        self._on_event = on_event or (lambda text: None)
        self._httpd = None
        self._udp = None
        self.running = False
        self.error = ""
        self._failed = {}
        self._clients = {}
        self._lock = threading.Lock()

    # --- lifecycle -----------------------------------------------
    def start(self):
        try:
            self._httpd = _Server(("0.0.0.0", HTTP_PORT), _Handler)
            self._httpd.sync = self
        except OSError as e:
            self.error = f"Port {HTTP_PORT} is busy or blocked ({e.strerror or e})."
            self.running = False
            return False
        threading.Thread(target=self._httpd.serve_forever, daemon=True).start()

        try:
            self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._udp.bind(("0.0.0.0", DISCOVERY_PORT))
            threading.Thread(target=self._discovery_loop, daemon=True).start()
        except OSError:
            # Discovery is a convenience; manual IP entry still works.
            self._udp = None

        self.running = True
        self.error = ""
        return True

    def stop(self):
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._udp:
            try:
                self._udp.close()
            except OSError:
                pass
            self._udp = None
        self.running = False

    def _discovery_loop(self):
        sock = self._udp
        while sock is not None and self._udp is sock:
            try:
                data, addr = sock.recvfrom(1024)
            except OSError:
                return
            if not data.startswith(DISCOVERY_MAGIC):
                continue
            reply = json.dumps({
                "app": "SpotVault",
                "api": API_VERSION,
                "name": socket.gethostname(),
                "port": HTTP_PORT,
            }).encode("utf-8")
            try:
                sock.sendto(reply, addr)
            except OSError:
                pass

    # --- auth bookkeeping ----------------------------------------
    def is_locked_out(self, ip):
        with self._lock:
            count, since = self._failed.get(ip, (0, 0))
            if count >= MAX_FAILED_PINS and time.time() - since < LOCKOUT_SECONDS:
                return True
            if count >= MAX_FAILED_PINS:
                self._failed.pop(ip, None)
            return False

    def note_failed_pin(self, ip):
        with self._lock:
            count, _ = self._failed.get(ip, (0, 0))
            self._failed[ip] = (count + 1, time.time())
        self._on_event(f"Wrong PIN from {ip}")

    def note_client(self, ip, device):
        with self._lock:
            self._failed.pop(ip, None)
            last = self._clients.get(ip, 0)
            self._clients[ip] = time.time()
        if time.time() - last > 300:
            self._on_event(f"{device} connected ({ip})")

    def note_sent(self, ip, rel):
        self._on_event(f"Sent {os.path.basename(rel)}")

    # --- library -------------------------------------------------
    def _snapshot(self):
        master, playlists = self._get_state()
        return os.path.realpath(master), [dict(p) for p in playlists]

    def build_library(self):
        master, playlists = self._snapshot()
        out = []
        for pl in playlists:
            folder = pl.get("folder", "")
            folder_path = os.path.join(master, folder)
            tracks = []
            if folder and os.path.isdir(folder_path):
                entries = []
                for entry in os.scandir(folder_path):
                    ext = os.path.splitext(entry.name)[1].lower()
                    if entry.is_file() and ext in AUDIO_MIME:
                        entries.append(entry)
                entries.sort(key=lambda e: e.name.casefold())
                for entry in entries:
                    st = entry.stat()
                    rel = f"{folder}/{entry.name}"
                    meta = read_track_meta(entry.path, st.st_size, int(st.st_mtime))
                    tracks.append({
                        "id": hashlib.sha1(rel.encode("utf-8")).hexdigest()[:16],
                        "path": rel,
                        "file": entry.name,
                        "size": st.st_size,
                        "mtime": int(st.st_mtime),
                        **meta,
                    })
            img = pl.get("img_path", "")
            out.append({
                "folder": folder,
                "title": pl.get("title", folder) or folder,
                "url": pl.get("url", ""),
                "has_cover": bool(img and os.path.isfile(img)),
                "tracks": tracks,
            })
        return {
            "api": API_VERSION,
            "name": socket.gethostname(),
            "generated": int(time.time()),
            "playlists": out,
        }

    def resolve_track(self, rel):
        """Maps a relative path to a real file inside a known playlist folder."""
        if not rel or "\x00" in rel:
            return None
        master, playlists = self._snapshot()
        parts = rel.replace("\\", "/").split("/")
        if len(parts) != 2 or parts[1] in ("", ".", ".."):
            return None
        folders = {p.get("folder") for p in playlists}
        if parts[0] not in folders:
            return None
        full = os.path.realpath(os.path.join(master, parts[0], parts[1]))
        if os.path.commonpath([full, master]) != master:
            return None
        if os.path.splitext(full)[1].lower() not in AUDIO_MIME or not os.path.isfile(full):
            return None
        return full

    def cover_path(self, folder):
        _, playlists = self._snapshot()
        for pl in playlists:
            if pl.get("folder") == folder:
                img = pl.get("img_path", "")
                if img and os.path.isfile(img):
                    return img
        return None
