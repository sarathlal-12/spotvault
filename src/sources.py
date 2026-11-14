"""Music sources for SpotVault.

Playlist links: Spotify (downloaded through spotdl) and YouTube, YouTube Music
and SoundCloud (downloaded directly with yt-dlp).
Song search: YouTube Music, YouTube and SoundCloud.

Every download is saved as "Artist - Title.m4a" with cover art and tags, the
same layout spotdl uses, so the phone sync code reads both the same way.
"""
import os
import re
import shutil
import sys
import urllib.parse

SPOTIFY = "spotify"
YOUTUBE = "youtube"
SOUNDCLOUD = "soundcloud"

SEARCH_SOURCES = {
    "YouTube Music": "ytmusic",
    "YouTube": "youtube",
    "SoundCloud": "soundcloud",
}

_SPOTIFY_RE = re.compile(
    r"^(https?://open\.spotify\.com/(intl-[a-zA-Z-]+/)?(playlist|album|track|artist)/[A-Za-z0-9]+"
    r"|spotify:(playlist|album|track|artist):[A-Za-z0-9]+)$"
)
_YT_HOSTS = ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be")
_SC_HOSTS = ("soundcloud.com", "www.soundcloud.com", "m.soundcloud.com", "on.soundcloud.com")

# Files yt-dlp writes to remember finished songs, so later syncs skip them.
ARCHIVE_NAME = ".spotvault_archive.txt"


# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------
def normalize_url(raw):
    """Return (source, clean_url) or (None, None) when the link is not supported."""
    url = (raw or "").strip()
    if not url:
        return None, None
    if url.startswith("spotify:"):
        return (SPOTIFY, url) if _SPOTIFY_RE.match(url) else (None, None)
    if "://" not in url:
        url = "https://" + url

    parts = urllib.parse.urlsplit(url)
    host = parts.netloc.lower()

    if host == "open.spotify.com":
        clean = f"https://open.spotify.com{parts.path}".rstrip("/")
        return (SPOTIFY, clean) if _SPOTIFY_RE.match(clean) else (None, None)

    if host in _YT_HOSTS:
        query = urllib.parse.parse_qs(parts.query)
        playlist_id = (query.get("list") or [""])[0]
        if playlist_id:
            base = "https://music.youtube.com" if host == "music.youtube.com" else "https://www.youtube.com"
            return YOUTUBE, f"{base}/playlist?list={playlist_id}"
        video_id = (query.get("v") or [""])[0]
        if host == "youtu.be":
            video_id = parts.path.strip("/")
        if video_id:
            return YOUTUBE, f"https://www.youtube.com/watch?v={video_id}"
        if parts.path.startswith(("/@", "/channel/", "/c/", "/user/")):
            return YOUTUBE, f"https://www.youtube.com{parts.path.rstrip('/')}"
        return None, None

    if host in _SC_HOSTS and parts.path.strip("/"):
        return SOUNDCLOUD, f"https://soundcloud.com{parts.path.rstrip('/')}" if host != "on.soundcloud.com" else url

    return None, None


def detect_source(url):
    return normalize_url(url)[0] or SPOTIFY


def source_label(source):
    return {SPOTIFY: "Spotify", YOUTUBE: "YouTube", SOUNDCLOUD: "SoundCloud"}.get(source, "Link")


# ---------------------------------------------------------------------------
# FFmpeg
# ---------------------------------------------------------------------------
def bundled_ffmpeg():
    """Path to the ffmpeg.exe packed inside the exe, if there is one."""
    base = getattr(sys, "_MEIPASS", None)
    candidates = []
    if base:
        candidates.append(os.path.join(base, "ffmpeg.exe"))
    candidates.append(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "ffmpeg.exe"))
    for path in candidates:
        if os.path.isfile(path):
            return path
    return None


def ensure_ffmpeg():
    """Make FFmpeg findable by spotdl and yt-dlp. Returns its path or None.

    Order: the copy bundled in the exe, then one already on the PC, then
    spotdl's one-time download into ~/.spotdl.
    """
    path = bundled_ffmpeg()
    if path:
        folder = os.path.dirname(path)
        if folder not in os.environ.get("PATH", "").split(os.pathsep):
            os.environ["PATH"] = folder + os.pathsep + os.environ.get("PATH", "")
        return path
    found = shutil.which("ffmpeg")
    if found:
        return found
    try:
        from spotdl.utils.ffmpeg import get_ffmpeg_path, download_ffmpeg
        local = get_ffmpeg_path()
        if local and os.path.isfile(local):
            return str(local)
        return str(download_ffmpeg())
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Metadata for the library tile
# ---------------------------------------------------------------------------
def fetch_metadata(source, url):
    """Return {"title", "thumbnail_url"} for a playlist link."""
    fallback = {"title": "Playlist", "thumbnail_url": ""}
    try:
        if source == SPOTIFY:
            import requests
            res = requests.get("https://open.spotify.com/oembed", params={"url": url}, timeout=6)
            if res.status_code == 200:
                data = res.json()
                return {"title": data.get("title") or "Playlist", "thumbnail_url": data.get("thumbnail_url", "")}
            return fallback

        import yt_dlp
        opts = {"quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True,
                "playlistend": 1, "logger": _SilentLogger()}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
        title = info.get("title") or "Playlist"
        thumb = _best_thumb(info.get("thumbnails"))
        if not thumb:
            entries = list(info.get("entries") or [])
            if entries:
                thumb = _best_thumb(entries[0].get("thumbnails")) or entries[0].get("thumbnail", "")
        return {"title": title, "thumbnail_url": thumb or info.get("thumbnail", "")}
    except Exception:
        return fallback


def _best_thumb(thumbs):
    if not thumbs:
        return ""
    best = max(thumbs, key=lambda t: (t.get("width") or 0) * (t.get("height") or 0))
    return best.get("url", "") or thumbs[-1].get("url", "")


# ---------------------------------------------------------------------------
# Clean music: no dialogue, skits or movie scenes
# ---------------------------------------------------------------------------
# Sources in the order SpotVault trusts them for a clean song:
#   1. YouTube Music "songs" (studio audio, never a video cut)
#   2. SoundCloud (audio uploads)
#   3. YouTube, searching lyric videos and skipping video cuts
CLEAN_ORDER = ("ytmusic", "soundcloud", "youtube")

# Titles that usually mean dialogue, scenes or a different version.
# A word is only banned when the song being looked for doesn't contain it.
BANNED_WORDS = (
    "video song", "full video", "music video", "official video", "scene", "trailer", "teaser",
    "making of", "making video", "dialogue", "dialog", "full movie", "jukebox", "reaction",
    "interview", "behind the scenes", "promo", "status", "8d", "slowed", "reverb", "nightcore",
    "sped up", "karaoke", "instrumental", "cover", "live", "1 hour", "hours", "loop", "mashup",
    "remix", "lofi", "lo-fi", "extended", "bass boosted",
)

_JUNK = re.compile(
    r"[\(\[\{][^\)\]\}]*?(official|video|lyric|audio|visuali[sz]er|\bhd\b|\bhq\b|4k|8k|full song|"
    r"remaster|explicit|clean|out now|from|ft\.?|feat\.?)[^\)\]\}]*[\)\]\}]",
    re.I,
)


def _norm(text):
    text = _JUNK.sub(" ", text or "")
    text = re.sub(r"\b(ft|feat|featuring)\b.*", " ", text, flags=re.I)
    text = re.sub(r"[^\w]+", " ", text.lower(), flags=re.UNICODE)
    return " ".join(text.split())


def _banned(candidate_title, wanted_text):
    cand = (candidate_title or "").lower()
    wanted = (wanted_text or "").lower()
    return any(w in cand and w not in wanted for w in BANNED_WORDS)


def _title_matches(cand_title, cand_artist, wanted_text):
    """Is this candidate the song described by wanted_text (an original title + uploader)?"""
    cand = _norm(cand_title).split()
    wanted = set(_norm(wanted_text).split())
    if not cand or not wanted:
        return False
    hit = sum(1 for t in cand if t in wanted) / len(cand)
    if hit < 0.8:
        return False
    # One-word titles ("Perfect", "Believer") need the artist too.
    if len(cand) == 1:
        artists = set(_norm(cand_artist).split())
        if not artists or not (artists & wanted):
            return False
    return True


def find_clean(title, uploader="", duration=None):
    """Find a clean copy of a song seen as a (possibly noisy) video.

    Returns (url, source_key) or (None, None). Tries CLEAN_ORDER in turn.
    """
    wanted_text = f"{title} {uploader}"
    query = _norm(title) or title
    for key in CLEAN_ORDER:
        try:
            results = search(key, query, 10)
        except Exception:
            continue
        for r in results:
            if _banned(r["title"], title):
                continue
            secs = r.get("secs") or 0
            if secs and secs < 60:
                continue
            if _title_matches(r["title"], r["artist"], wanted_text):
                return r["url"], key
    return None, None


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------
def search(source_key, query, limit=15):
    """Return a list of {"title", "artist", "duration", "secs", "url", "thumb"} results."""
    query = query.strip()
    if not query:
        return []
    if source_key == "ytmusic":
        from ytmusicapi import YTMusic
        out = []
        for r in YTMusic().search(query, filter="songs", limit=limit):
            vid = r.get("videoId")
            if not vid:
                continue
            artists = ", ".join(a.get("name", "") for a in (r.get("artists") or []) if a.get("name"))
            out.append({
                "title": r.get("title", ""),
                "artist": artists,
                "duration": r.get("duration") or "",
                "secs": r.get("duration_seconds") or 0,
                "url": f"https://music.youtube.com/watch?v={vid}",
                "thumb": _ytm_thumb(r.get("thumbnails")),
            })
        return out[:limit]

    import yt_dlp
    if source_key == "youtube":
        # Lyric videos carry the plain song: no intros, skits or dialogue.
        q, prefix = f"{query} lyrics", "ytsearch"
    else:
        q, prefix = query, "scsearch"
    opts = {"quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True,
            "logger": _SilentLogger()}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"{prefix}{limit}:{q}", download=False)
    out = []
    for e in info.get("entries") or []:
        # SoundCloud's "url" is an api.soundcloud.com link that normalize_url
        # rejects; its webpage_url is the normal soundcloud.com page.
        if source_key == "soundcloud":
            url = e.get("webpage_url") or e.get("url")
        else:
            url = e.get("url") or e.get("webpage_url")
        if not url:
            continue
        dur = e.get("duration")
        # SoundCloud returns 30-second previews for paid tracks; they are useless.
        if source_key == "soundcloud" and dur and dur <= 31:
            continue
        title = e.get("title", "")
        if source_key == "youtube" and _banned(title, query):
            continue
        out.append({
            "title": title,
            "artist": e.get("uploader") or e.get("channel") or "",
            "duration": _fmt_duration(dur),
            "secs": int(dur or 0),
            "url": url,
            "thumb": _best_thumb(e.get("thumbnails")) or e.get("thumbnail", ""),
        })
    if source_key == "youtube":
        # Lyric videos first, then audio uploads, then the rest.
        def rank(r):
            t = r["title"].lower()
            return 0 if "lyric" in t else 1 if "audio" in t else 2
        out.sort(key=rank)
    return out


def search_any(query, limit=15):
    """Search without asking the user for a source, in clean-music order
    (YouTube Music, SoundCloud, YouTube lyric videos), stopping at the first
    source that has results."""
    last_error = None
    for key in CLEAN_ORDER:
        try:
            results = search(key, query, limit)
        except Exception as e:
            last_error = e
            continue
        if results:
            return results
    if last_error:
        raise last_error
    return []


def _ytm_thumb(thumbs):
    """YouTube Music art comes as small squares; ask for a 544 px copy."""
    if not thumbs:
        return ""
    url = thumbs[-1].get("url", "")
    return re.sub(r"=w\d+-h\d+", "=w544-h544", url)


def _fmt_duration(seconds):
    if not seconds:
        return ""
    seconds = int(seconds)
    return f"{seconds // 60}:{seconds % 60:02d}"


# ---------------------------------------------------------------------------
# Download (YouTube / YouTube Music / SoundCloud)
# ---------------------------------------------------------------------------
class _SilentLogger:
    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        pass

    def error(self, msg):
        pass


class _ReportLogger:
    """Turns yt-dlp messages into SpotVault activity events."""

    def __init__(self, report):
        self.report = report

    def debug(self, msg):
        if "has already been recorded in the archive" in msg:
            self.report("skip", "A song already in this folder", "Already on disk (in the folder's download list)")

    def info(self, msg):
        self.debug(msg)

    def warning(self, msg):
        pass

    def error(self, msg):
        text = re.sub(r"\x1b\[[0-9;]*m", "", str(msg)).replace("ERROR:", "").strip()
        m = re.match(r"\[[^\]]+\]\s*([^:]+):\s*(.*)", text)
        title, why = (m.group(1), m.group(2)) if m else ("A song", text)
        self.report("fail", title[:140], why[:200] or "Could not download")


def download(urls, target_dir, report, ffmpeg_path=None):
    """Download one or more links (playlists or single songs) into target_dir.

    report(kind, title, detail) is called with kind "done", "skip" or "fail".
    Songs already listed in the folder's archive file are skipped.
    """
    import yt_dlp

    os.makedirs(target_dir, exist_ok=True)

    names = {source_name_for_url(u) for u in urls}
    saved = f"Saved from {names.pop()}" if len(names) == 1 else "Saved"

    def post_hook(filepath):
        name = os.path.splitext(os.path.basename(filepath))[0]
        report("done", name, saved)

    opts = {
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "outtmpl": {"default": os.path.join(target_dir, "%(artist,creator,uploader,channel|Unknown)s - %(track,title)s.%(ext)s")},
        "windowsfilenames": True,
        "trim_file_name": 150,
        "writethumbnail": True,
        "postprocessors": [
            # m4a can only hold JPEG/PNG covers; YouTube serves WebP.
            {"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"},
            {"key": "FFmpegExtractAudio", "preferredcodec": "m4a", "preferredquality": "0"},
            {"key": "FFmpegMetadata", "add_metadata": True},
            {"key": "EmbedThumbnail", "already_have_thumbnail": False},
        ],
        "postprocessor_args": {"thumbnailsconvertor+ffmpeg_o": ["-c:v", "mjpeg", "-vf", "crop=min(iw\\,ih):min(iw\\,ih)"]},
        "download_archive": os.path.join(target_dir, ARCHIVE_NAME),
        "ignoreerrors": True,
        "noplaylist": False,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "retries": 5,
        "fragment_retries": 5,
        "concurrent_fragment_downloads": 4,
        "post_hooks": [post_hook],
        "logger": _ReportLogger(report),
    }
    if ffmpeg_path:
        opts["ffmpeg_location"] = ffmpeg_path

    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download(list(urls))


# ---------------------------------------------------------------------------
# Preview (phone app plays a song before downloading it)
# ---------------------------------------------------------------------------
def resolve_stream(url):
    """Return (direct_audio_url, headers, mime) for streaming a song."""
    import yt_dlp
    opts = {"format": "bestaudio[ext=m4a]/bestaudio", "quiet": True, "no_warnings": True,
            "skip_download": True, "noplaylist": True, "logger": _SilentLogger()}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    if info.get("_type") == "playlist":
        info = (info.get("entries") or [None])[0] or {}
    direct = info.get("url")
    if not direct:
        raise RuntimeError("No playable stream")
    ext = info.get("ext", "m4a")
    mime = {"m4a": "audio/mp4", "mp4": "audio/mp4", "webm": "audio/webm", "mp3": "audio/mpeg",
            "opus": "audio/ogg"}.get(ext, "application/octet-stream")
    return direct, dict(info.get("http_headers") or {}), mime


# ---------------------------------------------------------------------------
# YouTube playlists: swap each video for a clean copy of the song
# ---------------------------------------------------------------------------
MATCHES_NAME = ".spotvault_matches.json"


def sync_youtube(url, target_dir, report, ffmpeg_path=None):
    """Sync a YouTube / YouTube Music playlist (or one video) into target_dir.

    Each video is matched to a clean copy of its song (YouTube Music song,
    then SoundCloud, then a YouTube lyric video); the original video is only
    used when none is found. Matched videos are remembered, so later syncs
    skip them without searching again.
    """
    import json
    import yt_dlp

    os.makedirs(target_dir, exist_ok=True)
    opts = {"quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True,
            "logger": _SilentLogger()}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    entries = [e for e in (info.get("entries") if info.get("entries") is not None else [info]) if e and e.get("id")]

    path = os.path.join(target_dir, MATCHES_NAME)
    try:
        with open(path, encoding="utf-8") as f:
            done = json.load(f)
    except (OSError, ValueError):
        done = {}

    def save():
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(done, f, indent=1)
        os.replace(tmp, path)

    for e in entries:
        vid = e["id"]
        title = e.get("title") or ""
        if vid in done:
            report("skip", done[vid].get("name") or title, "Already in this folder")
            continue
        if title in ("[Private video]", "[Deleted video]"):
            report("fail", f"{title} ({vid})", "Not available: the video is private or deleted")
            continue

        clean_url, key = find_clean(title, e.get("uploader") or e.get("channel") or "", e.get("duration"))
        target = clean_url or (e.get("url") or f"https://www.youtube.com/watch?v={vid}")
        outcome = {}

        def item_report(kind, name, detail):
            outcome.setdefault(kind, name)
            if kind == "done":
                detail = (f"Saved from {source_name_for_url(clean_url)}" if clean_url
                          else "Saved from the original video (no clean copy found)")
            elif kind == "fail":
                name, detail = title or name, detail
            report(kind, name, detail)

        download([target], target_dir, item_report, ffmpeg_path)
        if "done" in outcome or "skip" in outcome:
            done[vid] = {"url": target, "source": key or "original", "name": outcome.get("done") or title}
            save()


# ---------------------------------------------------------------------------
# Spotify playlists (spotdl): same clean-music rules
# ---------------------------------------------------------------------------
SPOTDL_AUDIO_ORDER = ["youtube-music", "soundcloud", "youtube"]
_spotdl_patched = False


def apply_spotdl_clean_rules():
    """Make spotdl pick clean songs: YouTube Music studio songs only (no music
    videos), and on YouTube search lyric videos and skip video cuts."""
    global _spotdl_patched
    if _spotdl_patched:
        return
    from spotdl.providers.audio.youtube import YouTube
    from spotdl.providers.audio.ytmusic import YouTubeMusic

    YouTubeMusic.GET_RESULTS_OPTS = [{"filter": "songs", "ignore_spelling": True, "limit": 50}]

    original = YouTube.get_results

    def clean_get_results(self, search_term, *args, **kwargs):
        results = original(self, f"{search_term} lyrics", *args, **kwargs)
        results = [r for r in results if not _banned(r.name, search_term)]
        results.sort(key=lambda r: 0 if "lyric" in r.name.lower() else 1 if "audio" in r.name.lower() else 2)
        return results

    YouTube.get_results = clean_get_results

    # spotdl's own scoring rejects some songs whose titles differ between
    # Spotify and the sources (e.g. "(From "RRR")"). Before giving up, try
    # SpotVault's clean matcher; spotdl then downloads and tags it as usual.
    from spotdl.download.downloader import Downloader
    original_search = Downloader.search

    def search_with_fallback(self, song):
        try:
            url = original_search(self, song)
        except LookupError:
            artists = ", ".join(song.artists or [])
            url, _ = find_clean(f"{artists} - {song.name}" if artists else song.name, "", song.duration)
            if not url:
                raise
        _spotdl_picked[song.url] = url
        return url

    Downloader.search = search_with_fallback

    # YouTube sometimes refuses one download (busy, throttled). spotdl gives up
    # on that song at once; retry it twice with a short pause first. Only
    # failures that survive the retries are reported (see spotdl_failures).
    import asyncio
    original_download = Downloader.async_search_and_download

    async def download_with_retry(self, song):
        for attempt in range(3):
            song_out, path = await original_download(self, song)
            if path is not None:
                picked = _spotdl_picked.pop(song.url, None)
                if picked is None:
                    # spotdl found the file before searching: nothing downloaded.
                    _spotdl_emit("skip", song.display_name, f"Already on disk: {os.path.basename(str(path))}", str(path))
                else:
                    _spotdl_emit("done", song.display_name, f"Saved from {source_name_for_url(picked)}", str(path))
                return song_out, path
            mine = [e for e in self.errors if e.startswith(song.url)]
            not_found = any("LookupError" in e for e in mine)
            if attempt == 2 or not_found:
                text = " ".join(mine)
                if not_found:
                    detail = "No clean copy found on YouTube Music, SoundCloud or YouTube"
                elif classify_failure(text) == "unavailable":
                    detail = "Not available: " + _short_error(text)
                elif classify_failure(text) == "other":
                    detail = "Error: " + _short_error(text)
                else:
                    detail = "Download refused by the source after 3 tries (" + _short_error(text) + ")"
                _spotdl_picked.pop(song.url, None)
                spotdl_failures.append((song.display_name, detail))
                _spotdl_emit("fail", song.display_name, detail, "")
                return song_out, path
            for e in mine:
                self.errors.remove(e)
            await asyncio.sleep(4 + attempt * 6)

    Downloader.async_search_and_download = download_with_retry
    _spotdl_patched = True


# Songs spotdl could not get, filled during a run: [(display name, reason)].
spotdl_failures = []

# Set by the app: called as listener(kind, title, detail, path) for each song.
spotdl_listener = None
_spotdl_picked = {}


def _spotdl_emit(kind, title, detail, path):
    if spotdl_listener is not None:
        try:
            spotdl_listener(kind, title, detail, path)
        except Exception:
            pass


def _short_error(text, limit=110):
    text = re.sub(r"https?://\S+", "", text or "")
    text = re.sub(r"^.*?(Error|Exception):\s*", "", text.strip())
    text = " ".join(text.split())
    return (text[:limit] + "…") if len(text) > limit else (text or "unknown error")


def source_name_for_url(url):
    u = (url or "").lower()
    if "music.youtube.com" in u:
        return "YouTube Music"
    if "soundcloud.com" in u:
        return "SoundCloud"
    if "youtube.com" in u or "youtu.be" in u:
        return "YouTube"
    return "the web"


# ---------------------------------------------------------------------------
# Sync report: why each song failed, was skipped or where it came from
# ---------------------------------------------------------------------------
# kind -> group -> (title, why it happens, what you can do)
REASONS = {
    "fail": {
        "no_clean": ("No clean copy found",
                     "Only covers, teasers, live versions or movie-scene cuts exist online. SpotVault skips those so "
                     "your library never gets dialogue or the wrong singer.",
                     "Fix: pick a version yourself with Find a version."),
        "refused": ("Source refused the download",
                    "YouTube or SoundCloud turned the download away 3 times in a row because it was busy or "
                    "rate-limited. It usually works on the next try.",
                    "Fix: Retry, ideally in a few minutes."),
        "unavailable": ("Not available",
                        "The song or video was removed, made private, age-restricted or blocked in your country.",
                        "Nothing to fix. Find another version if you still want it."),
        "other": ("Other errors",
                  "Something unexpected went wrong. Each song shows the message.",
                  "Fix: Retry. If it keeps failing, copy the list and report it."),
    },
    "skip": {
        "on_disk": ("Already on your PC",
                    "Downloaded in an earlier sync, so it wasn't downloaded again.",
                    "Nothing to do."),
        "local": ("Local file or podcast",
                  "Someone added this to the Spotify playlist from their own computer, or it is a podcast episode. "
                  "There is nothing online to download.",
                  "Copy the file into the playlist folder yourself."),
        "explicit": ("Explicit song filtered",
                     "This song is marked explicit and explicit songs were turned off.",
                     "Nothing to do."),
    },
    "done": {
        "ytmusic": ("From YouTube Music", "Clean studio versions, the first choice.", ""),
        "soundcloud": ("From SoundCloud", "Used when YouTube Music didn't have the song.", ""),
        "youtube": ("From YouTube", "Lyric videos and audio uploads, checked for scenes and dialogue.", ""),
        "original": ("Original video", "Saved from the playlist's own video because no clean copy was found.", ""),
        "other": ("Saved", "Songs you picked in Search, or saved without a source label.", ""),
    },
}


def classify_failure(text):
    t = (text or "").lower()
    if "lookuperror" in t or "no clean copy" in t or "no results" in t:
        return "no_clean"
    if any(k in t for k in ("private", "deleted", "unavailable", "not available", "removed", "copyright",
                            "age-restricted", "age restricted", "confirm your age", "region", "blocked", "missing required fields",
                            "terminated")):
        return "unavailable"
    if any(k in t for k in ("403", "429", "too many requests", "refused", "forbidden", "timed out", "timeout",
                            "connection", "http error", "rate", "busy", "reset", "temporarily")):
        return "refused"
    return "other"


def group_for(kind, detail):
    """Report group for one song, from its kind and detail text."""
    d = (detail or "").lower()
    if kind == "fail":
        return classify_failure(d)
    if kind == "skip":
        if "local" in d or "podcast" in d:
            return "local"
        if "explicit" in d:
            return "explicit"
        return "on_disk"
    if "original video" in d:
        return "original"
    if "youtube music" in d:
        return "ytmusic"
    if "soundcloud" in d:
        return "soundcloud"
    if "youtube" in d:
        return "youtube"
    return "other"
