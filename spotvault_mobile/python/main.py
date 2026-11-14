"""SpotVault on-phone downloader.

Runs inside the phone app (serious_python) as a tiny HTTP service on
127.0.0.1. It speaks the same API as the PC's phone-sync server, so the app
uses one code path for both:

    GET  /api/status
    GET  /api/search?q=<text>          clean-first search (same filter as the PC)
    GET  /api/preview?url=<song>       streams a result for a listen
    POST /api/download                 {"url","folder","title","artist","thumb"}
    GET  /api/job?id=<id>              download progress / result

Every request except /api/status needs the token the app passed in
SV_TOKEN (header X-SpotVault-Pin or ?pin=), so other apps on the phone
can't use it.

The phone has no FFmpeg, so songs are saved as the original audio stream
(m4a from YouTube Music, mp3 from SoundCloud) and tagged with mutagen.
`sources.py` is copied in from the PC app at build time: the clean-music
filter is the same file on both.
"""
import json
import os
import re
import secrets
import sys
import threading
import time
import traceback
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SV_PORT", "0") or 0)
TOKEN = os.environ.get("SV_TOKEN", "")
MUSIC = os.environ.get("SV_MUSIC", os.path.join(os.getcwd(), "Music"))
ART = os.environ.get("SV_ART", os.path.join(os.getcwd(), "art"))
LOG = os.environ.get("SV_LOG", "")
VERSION = os.environ.get("SV_VERSION", "")
CHUNK = 64 * 1024


def log(*parts):
    line = time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts)
    print(line, flush=True)
    if LOG:
        try:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


# Mobile Python has no system CA store; point SSL at certifi's bundle.
try:
    import certifi
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
    os.environ.setdefault("REQUESTS_CA_BUNDLE", certifi.where())
except Exception as e:  # pragma: no cover
    log("certifi missing:", e)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sources  # noqa: E402  (the PC app's clean-music search)

# yt-dlp options shared by preview and download. No JS runtime or FFmpeg on a phone.
YDL_BASE = {
    "quiet": True,
    "no_warnings": True,
    "noplaylist": True,
    "cachedir": False,
    "js_runtimes": {},
    "retries": 5,
    "fragment_retries": 5,
}
# Formats a phone can play without converting: AAC/m4a first, then mp3.
AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio[ext=mp3]/bestaudio[acodec=mp3]"

_jobs = {}
_queue = []
_cv = threading.Condition()
_streams = {}
_streams_lock = threading.Lock()


class _Quiet:
    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        pass

    def error(self, msg):
        log("yt-dlp:", msg)


# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------
def _safe(name):
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]+', " ", name or "")
    name = " ".join(name.split()).strip(" .")
    return name[:150] or "Unknown"


def _art_bytes(thumb, info):
    """Square cover art: the YouTube Music thumb when we have it, else the video's JPEG."""
    import requests
    urls = []
    if thumb:
        urls.append(thumb)
    for t in reversed(info.get("thumbnails") or []):
        u = t.get("url") or ""
        if u.split("?")[0].endswith((".jpg", ".jpeg", ".png")):
            urls.append(u)
    if info.get("thumbnail"):
        urls.append(info["thumbnail"])
    for u in urls:
        try:
            r = requests.get(u, timeout=15)
            data = r.content
            if r.status_code == 200 and (data[:2] == b"\xff\xd8" or data[:4] == b"\x89PNG"):
                return data
        except Exception:
            continue
    return None


def _tag(path, title, artist, album, art):
    """Write title/artist/album/cover; returns the song length in seconds."""
    try:
        if path.lower().endswith(".mp3"):
            from mutagen.id3 import APIC, ID3, ID3NoHeaderError, TALB, TIT2, TPE1
            from mutagen.mp3 import MP3
            try:
                tags = ID3(path)
            except ID3NoHeaderError:
                tags = ID3()
            tags.add(TIT2(encoding=3, text=title))
            tags.add(TPE1(encoding=3, text=artist))
            if album:
                tags.add(TALB(encoding=3, text=album))
            if art:
                mime = "image/png" if art[:4] == b"\x89PNG" else "image/jpeg"
                tags.add(APIC(encoding=3, mime=mime, type=3, desc="Cover", data=art))
            tags.save(path)
            return float(MP3(path).info.length or 0)
        from mutagen.mp4 import MP4, MP4Cover
        m = MP4(path)
        m["\xa9nam"] = title
        m["\xa9ART"] = artist
        if album:
            m["\xa9alb"] = album
        if art:
            fmt = MP4Cover.FORMAT_PNG if art[:4] == b"\x89PNG" else MP4Cover.FORMAT_JPEG
            m["covr"] = [MP4Cover(art, imageformat=fmt)]
        m.save()
        return float(MP4(path).info.length or 0)
    except Exception as e:
        log("tagging failed:", type(e).__name__, e)
        return 0.0


def _run(job):
    import yt_dlp
    folder_dir = os.path.join(MUSIC, job["folder"])
    tmp = os.path.join(folder_dir, ".sv_tmp")
    os.makedirs(tmp, exist_ok=True)
    opts = dict(YDL_BASE, format=AUDIO_FORMAT, logger=_Quiet(),
                outtmpl={"default": os.path.join(tmp, "%(id)s.%(ext)s")})
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(job["url"], download=True)
        if info.get("_type") == "playlist":
            info = (info.get("entries") or [None])[0] or {}
        reqs = info.get("requested_downloads") or []
        src = reqs[0].get("filepath") if reqs else ydl.prepare_filename(info)
    if not src or not os.path.exists(src):
        raise RuntimeError("No playable audio for this song")

    title = job["title"] or info.get("track") or info.get("title") or "Unknown"
    artist = job["artist"] or info.get("artist") or info.get("uploader") or info.get("channel") or ""
    album = info.get("album") or ""
    ext = os.path.splitext(src)[1].lower() or ".m4a"
    name = _safe(f"{artist} - {title}" if artist else title) + ext
    dest = os.path.join(folder_dir, name)
    already = os.path.exists(dest)
    if already:
        os.remove(src)
    else:
        os.replace(src, dest)
        art = _art_bytes(job["thumb"], info)
        if art:
            os.makedirs(ART, exist_ok=True)
            with open(os.path.join(ART, job["id"] + ".img"), "wb") as f:
                f.write(art)
            job["art"] = os.path.join(ART, job["id"] + ".img")
        job["duration"] = _tag(dest, title, artist, album, art)
    try:
        os.rmdir(tmp)
    except OSError:
        pass
    st = os.stat(dest)
    if already:
        try:
            from mutagen import File as MFile
            job["duration"] = float(MFile(dest).info.length or 0)
        except Exception:
            pass
    job.update(state="done", path=f"{job['folder']}/{name}", already=already, size=st.st_size,
               mtime=int(st.st_mtime), title=title, artist=artist, album=album,
               source=sources.source_name_for_url(job["url"]))


def _worker():
    while True:
        with _cv:
            while not _queue:
                _cv.wait()
            job = _jobs.get(_queue.pop(0))
            if not job:
                continue
            job["state"] = "working"
        try:
            _run(job)
            log("saved", job.get("path"))
        except Exception as e:
            msg = str(e)
            msg = re.sub(r"^ERROR:\s*", "", msg)
            msg = re.sub(r"\x1b\[[0-9;]*m", "", msg)
            job.update(state="failed", error=(msg or type(e).__name__)[:240])
            log("download failed:", type(e).__name__, msg)
            log(traceback.format_exc())


def start_download(data):
    url = str(data.get("url", ""))
    folder = _safe(str(data.get("folder", "")))
    source, clean = sources.normalize_url(url)
    if not clean or source == sources.SPOTIFY:
        return None, "Unsupported link"
    job = {"id": uuid.uuid4().hex[:12], "state": "queued", "url": clean, "folder": folder,
           "title": str(data.get("title", ""))[:200], "artist": str(data.get("artist", ""))[:200],
           "thumb": str(data.get("thumb", ""))[:1000], "path": "", "error": "", "art": "",
           "duration": 0, "created": time.time()}
    with _cv:
        now = time.time()
        for jid in [j for j, v in _jobs.items() if v["state"] in ("done", "failed") and now - v["created"] > 3600]:
            _jobs.pop(jid, None)
        _jobs[job["id"]] = job
        _queue.append(job["id"])
        _cv.notify()
    return dict(job), None


def stream_for(url):
    with _streams_lock:
        hit = _streams.get(url)
        if hit and time.time() - hit[0] < 1800:
            return hit[1]
    import yt_dlp
    opts = dict(YDL_BASE, format=AUDIO_FORMAT, skip_download=True, logger=_Quiet())
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    if info.get("_type") == "playlist":
        info = (info.get("entries") or [None])[0] or {}
    direct = info.get("url")
    if not direct:
        raise RuntimeError("No playable stream")
    mime = {"m4a": "audio/mp4", "mp4": "audio/mp4", "mp3": "audio/mpeg"}.get(info.get("ext", ""), "audio/mp4")
    resolved = (direct, dict(info.get("http_headers") or {}), mime)
    with _streams_lock:
        if len(_streams) > 50:
            _streams.clear()
        _streams[url] = (time.time(), resolved)
    return resolved


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, msg):
        self._json(code, {"error": msg})

    def _authorized(self):
        given = self.headers.get("X-SpotVault-Pin", "")
        if not given:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            given = q.get("pin", [""])[0]
        if TOKEN and secrets.compare_digest(given.encode(), TOKEN.encode()):
            return True
        self._error(401, "Wrong token")
        return False

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        route = parsed.path.rstrip("/")
        try:
            if route == "/api/status":
                return self._json(200, {"app": "SpotVault", "engine": "phone", "version": VERSION})
            if not self._authorized():
                return
            if route == "/api/search":
                return self._search(q.get("q", [""])[0])
            if route == "/api/preview":
                return self._preview(q.get("url", [""])[0])
            if route == "/api/job":
                with _cv:
                    job = _jobs.get(q.get("id", [""])[0])
                    job = dict(job) if job else None
                return self._json(200, job) if job else self._error(404, "Unknown job")
            if route == "/api/log":
                text = ""
                if LOG and os.path.exists(LOG):
                    with open(LOG, encoding="utf-8", errors="replace") as f:
                        text = f.read()[-20000:]
                return self._json(200, {"log": text})
            self._error(404, "Not found")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_POST(self):
        route = urllib.parse.urlparse(self.path).path.rstrip("/")
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(min(length, 64 * 1024)) if length > 0 else b""
            if not self._authorized():
                return
            if route == "/api/download":
                try:
                    data = json.loads(body or b"{}")
                except ValueError:
                    return self._error(400, "Bad JSON")
                job, err = start_download(data)
                return self._error(400, err) if err else self._json(200, job)
            self._error(404, "Not found")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _search(self, text):
        text = text.strip()[:200]
        if not text:
            return self._json(200, {"results": []})
        try:
            results = sources.search_any(text, 20)
        except Exception as e:
            log("search failed:", type(e).__name__, e)
            return self._error(502, f"Search failed: {type(e).__name__}")
        return self._json(200, {"results": [
            {k: r.get(k, "") for k in ("title", "artist", "duration", "url", "thumb")} for r in results
        ]})

    def _preview(self, url):
        import requests
        source, clean = sources.normalize_url(url)
        if not clean or source == sources.SPOTIFY:
            return self._error(400, "Unsupported link")
        try:
            direct, headers, mime = stream_for(clean)
        except Exception as e:
            log("preview failed:", type(e).__name__, e)
            return self._error(502, f"Preview failed: {type(e).__name__}")
        rng = self.headers.get("Range", "")
        up_headers = dict(headers)
        up_headers["Range"] = rng if rng.startswith("bytes=") else "bytes=0-"
        try:
            up = requests.get(direct, headers=up_headers, stream=True, timeout=20)
        except Exception:
            return self._error(502, "Stream unavailable")
        try:
            if up.status_code not in (200, 206):
                with _streams_lock:
                    _streams.pop(clean, None)
                return self._error(502, f"Stream answered {up.status_code}")
            self.send_response(up.status_code)
            self.send_header("Content-Type", mime)
            self.send_header("Accept-Ranges", "bytes")
            for h in ("Content-Length", "Content-Range"):
                if up.headers.get(h):
                    self.send_header(h, up.headers[h])
            self.end_headers()
            for chunk in up.iter_content(CHUNK):
                if chunk:
                    self.wfile.write(chunk)
        finally:
            up.close()


def main():
    threading.Thread(target=_worker, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    log("SpotVault phone engine on port", server.server_address[1])
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log("engine crashed:", traceback.format_exc())
        raise
