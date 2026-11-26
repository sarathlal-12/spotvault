"""SpotVault MCP server: lets AI assistants (Claude Desktop, Claude Code, Cursor...)
see what's trending, search songs and save them into SpotVault playlists.

Run as:  SpotVaultEngine.exe --mcp   (or: python src/engine.py --mcp)

It speaks MCP over stdio (newline-delimited JSON-RPC). Charts and search run
here; saving a song asks the running SpotVault app on this PC to download it
(the same way a phone does), so the song lands in the user's library.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import sources

PORT = 50505
SERVER_INFO = {"name": "spotvault", "version": "2.4.0"}

_PL = {"type": "array", "items": {"type": "string"},
       "description": "Playlist folder names from list_playlists (one or more). A song saved into several playlists is stored once."}
_SONG = {"type": "object", "properties": {
    "url": {"type": "string", "description": "Song link from another tool (best)."},
    "title": {"type": "string"}, "artist": {"type": "string"}}}

TOOLS = [
    {
        "name": "search_songs",
        "description": "Search for any song online (YouTube Music first, then SoundCloud and YouTube), clean studio "
                       "versions preferred. Returns title, artist, length and a link.",
        "inputSchema": {"type": "object", "required": ["query"], "properties": {
            "query": {"type": "string", "description": "Song name and artist."}}},
    },
    {
        "name": "songs_like",
        "description": "Find new music: songs similar to one song (YouTube Music's radio for it). Give a link or a "
                       "song name and artist.",
        "inputSchema": {"type": "object", "properties": {
            "url": {"type": "string", "description": "Song link (optional)."},
            "query": {"type": "string", "description": "Song name and artist, used when there is no link."},
            "limit": {"type": "integer", "description": "How many (1-50). Default 25."}}},
    },
    {
        "name": "artist_music",
        "description": "An artist's newest singles and albums (newest first) and their top songs.",
        "inputSchema": {"type": "object", "required": ["artist"], "properties": {
            "artist": {"type": "string", "description": "Artist name."}}},
    },
    {
        "name": "album_songs",
        "description": "Every song on an album. Give the album id from artist_music, or the album name and artist.",
        "inputSchema": {"type": "object", "properties": {
            "album_id": {"type": "string", "description": "Album id from artist_music (optional)."},
            "query": {"type": "string", "description": "Album name and artist, used when there is no id."}}},
    },
    {
        "name": "playlist_songs",
        "description": "The songs of a YouTube, YouTube Music, SoundCloud or Spotify playlist or album link.",
        "inputSchema": {"type": "object", "required": ["url"], "properties": {
            "url": {"type": "string", "description": "Playlist or album link."}}},
    },
    {
        "name": "list_charts",
        "description": "Music charts for a country: Apple Music Top 50 plus YouTube Music lists (in India also "
                       "Hindi, Tamil, Telugu, Punjabi and more).",
        "inputSchema": {"type": "object", "properties": {
            "country": {"type": "string", "description": "Two-letter country code, e.g. IN, US, GB. Default IN."}}},
    },
    {
        "name": "get_trending",
        "description": "Today's songs on one chart (from list_charts).",
        "inputSchema": {"type": "object", "properties": {
            "country": {"type": "string", "description": "Two-letter country code. Default IN."},
            "chart": {"type": "string", "description": "Chart id from list_charts. Default 'apple'."},
            "limit": {"type": "integer", "description": "How many songs (1-100). Default 25."}}},
    },
    {
        "name": "list_playlists",
        "description": "The user's SpotVault playlists on this PC, with how many songs each has.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "library_songs",
        "description": "The songs the user already has (title and artist), so you can skip ones they own and suggest "
                       "music to their taste. Optionally one playlist, or only songs matching some words.",
        "inputSchema": {"type": "object", "properties": {
            "playlist": {"type": "string", "description": "Only this playlist (optional)."},
            "query": {"type": "string", "description": "Only songs whose title or artist has these words (optional)."},
            "limit": {"type": "integer", "description": "Most songs to return (default 500)."}}},
    },
    {
        "name": "create_playlist",
        "description": "Make a new, empty playlist in SpotVault (for example 'Rainy Day'), then save songs into it. "
                       "Opens SpotVault if it is closed.",
        "inputSchema": {"type": "object", "required": ["name"], "properties": {
            "name": {"type": "string", "description": "Playlist name."}}},
    },
    {
        "name": "save_songs",
        "description": "Download songs into one or more of the user's playlists. Give songs (links from other tools, "
                       "or title and artist), or a playlist/album link to save all of it. Opens SpotVault if it is "
                       "closed. Songs download in the background and appear in SpotVault when done.",
        "inputSchema": {"type": "object", "required": ["playlists"], "properties": {
            "playlists": _PL,
            "songs": {"type": "array", "items": _SONG, "description": "Songs to save (up to 200)."},
            "playlist_url": {"type": "string", "description": "Save every song of this playlist or album link."}}},
    },
    {
        "name": "save_song",
        "description": "Download one song into a playlist (same as save_songs with one song).",
        "inputSchema": {"type": "object", "required": ["playlist"], "properties": {
            "playlist": {"type": "string", "description": "Playlist folder name, from list_playlists."},
            "url": {"type": "string", "description": "Song link (optional)."},
            "query": {"type": "string", "description": "Song name and artist, used when there is no link."}}},
    },
]

AUDIO = (".m4a", ".mp3", ".opus", ".ogg", ".flac", ".wav", ".webm")


def _config():
    try:
        with open("library_config.json", "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _playlists():
    return [p.get("folder", "") for p in _config().get("playlists") or [] if p.get("folder")]


def _app_exe():
    """SpotVault.exe next to the engine folder (installed app)."""
    here = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, "frozen", False) else __file__))
    for cand in (os.path.join(os.path.dirname(here), "SpotVault.exe"), os.path.join(here, "SpotVault.exe"),
                 os.path.join(os.getcwd(), "SpotVault.exe")):
        if os.path.isfile(cand):
            return cand
    return None


def _app_up():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/status", timeout=2):
            return True
    except Exception:
        return False


def _open_app():
    """Starts SpotVault minimised when it isn't running, and waits for it."""
    if _app_up():
        return True
    exe = _app_exe()
    if not exe:
        return False
    import subprocess
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 7  # SW_SHOWMINNOACTIVE: minimised, doesn't take focus
    env = dict(os.environ, SV_START_MINIMIZED="1")
    subprocess.Popen([exe, "--minimized"], cwd=os.path.dirname(exe), startupinfo=si, env=env,
                     creationflags=0x00000008)  # DETACHED_PROCESS: lives on after the AI app closes
    for _ in range(60):
        time.sleep(1)
        if _app_up():
            time.sleep(1)
            return True
    return False


def _post(path, body):
    if not _app_up() and not _open_app():
        raise RuntimeError("SpotVault isn't running and couldn't be opened. Open the SpotVault app on this PC, then try again.")
    pin = str(_config().get("sync_pin", ""))
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "X-SpotVault-Pin": pin})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read().decode()).get("error")
        except Exception:
            msg = None
        raise RuntimeError(msg or f"SpotVault answered {e.code}")
    except OSError:
        raise RuntimeError("SpotVault isn't running. Open the SpotVault app on this PC, then try again.")


def _yt():
    from ytmusicapi import YTMusic
    return YTMusic()


def _artists(x):
    return ", ".join(a.get("name", "") for a in (x.get("artists") or []) if a.get("name"))


def _video_id(url):
    import re
    m = re.search(r"(?:v=|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})", url or "")
    return m.group(1) if m else ""


def _song_out(t):
    vid = t.get("videoId")
    return {"title": t.get("title", ""), "artist": _artists(t),
            "url": f"https://music.youtube.com/watch?v={vid}" if vid else "",
            "length": t.get("length") or t.get("duration") or ""}


def songs_like(args):
    limit = max(1, min(int(args.get("limit") or 25), 50))
    vid = _video_id(str(args.get("url") or ""))
    if not vid:
        q = str(args.get("query") or "").strip()
        if not q:
            raise ValueError("Give a song link (url) or a song name (query).")
        hits = _yt().search(q, filter="songs", limit=3)
        vid = next((h.get("videoId") for h in hits if h.get("videoId")), "")
        if not vid:
            raise ValueError(f"Couldn't find '{q}' on YouTube Music.")
    tracks = _yt().get_watch_playlist(videoId=vid, radio=True, limit=limit + 1).get("tracks") or []
    return [_song_out(t) for t in tracks if t.get("videoId") and t.get("videoId") != vid][:limit]


def artist_music(args):
    name = str(args.get("artist") or "").strip()
    if not name:
        raise ValueError("Give an artist name.")
    yt = _yt()
    hits = yt.search(name, filter="artists", limit=3)
    if not hits:
        raise ValueError(f"No artist called '{name}' on YouTube Music.")
    a = yt.get_artist(hits[0]["browseId"])
    releases = []
    for kind in ("singles", "albums"):
        for r in (a.get(kind) or {}).get("results") or []:
            releases.append({"type": "single" if kind == "singles" else (r.get("type") or "album").lower(),
                             "title": r.get("title", ""), "year": r.get("year", ""),
                             "album_id": r.get("browseId", "")})
    releases.sort(key=lambda r: str(r.get("year") or ""), reverse=True)
    top = [_song_out(s) for s in ((a.get("songs") or {}).get("results") or [])]
    return {"artist": a.get("name", name), "newest_releases": releases[:20], "top_songs": top[:20]}


def album_songs(args):
    yt = _yt()
    bid = str(args.get("album_id") or "").strip()
    if not bid:
        q = str(args.get("query") or "").strip()
        if not q:
            raise ValueError("Give an album_id or the album name (query).")
        hits = yt.search(q, filter="albums", limit=3)
        if not hits:
            raise ValueError(f"No album '{q}' on YouTube Music.")
        bid = hits[0]["browseId"]
    al = yt.get_album(bid)
    return {"album": al.get("title", ""), "artist": _artists(al), "year": al.get("year", ""),
            "songs": [_song_out(t) for t in al.get("tracks") or [] if t.get("videoId")]}


def library_songs(args):
    cfg = _config()
    master = cfg.get("master_folder") or os.path.join(os.path.expanduser("~"), "Music")
    only = str(args.get("playlist") or "").strip()
    words = [w for w in str(args.get("query") or "").lower().split() if w]
    limit = max(1, min(int(args.get("limit") or 500), 5000))
    out, seen = [], set()
    for folder in _playlists():
        if only and folder != only:
            continue
        try:
            names = sorted(os.listdir(os.path.join(master, folder)))
        except OSError:
            continue
        for n in names:
            if not n.lower().endswith(AUDIO):
                continue
            stem = os.path.splitext(n)[0]
            artist, title = stem.split(" - ", 1) if " - " in stem else ("", stem)
            if words and not all(w in stem.lower() for w in words):
                continue
            key = (title.lower(), artist.lower())
            if key in seen and not only:
                for o in out:
                    if (o["title"].lower(), o["artist"].lower()) == key and folder not in o["playlists"]:
                        o["playlists"].append(folder)
                continue
            seen.add(key)
            out.append({"title": title, "artist": artist, "playlists": [folder]})
            if len(out) >= limit:
                return out
    return out


def _resolve(song):
    url = str(song.get("url") or "").strip()
    if url:
        return url, str(song.get("title") or "")
    q = " ".join(x for x in (str(song.get("title") or ""), str(song.get("artist") or "")) if x).strip()
    if not q:
        return "", ""
    hits = sources.search_any(q, 3)
    return (hits[0].get("url", ""), hits[0].get("title", "")) if hits else ("", q)


def save_songs(args):
    targets = [str(x).strip() for x in (args.get("playlists") or []) if str(x).strip()]
    mine = _playlists()
    missing = [t for t in targets if t not in mine]
    if not targets:
        raise ValueError("Give at least one playlist (see list_playlists, or create_playlist first).")
    if missing:
        raise ValueError(f"No playlist called {', '.join(repr(m) for m in missing)}. Use list_playlists or create_playlist.")
    songs = list(args.get("songs") or [])
    if args.get("playlist_url"):
        songs += sources.list_tracks(str(args["playlist_url"]))
    songs = songs[:200]
    if not songs:
        raise ValueError("Give songs or a playlist_url.")
    queued, failed = [], []
    for s in songs:
        url, title = _resolve(s)
        name = title or s.get("title") or url
        if not url:
            failed.append(f"{name}: no copy found online")
            continue
        try:
            job = _post("/api/download", {"url": url, "folder": targets[0], "title": name, "also": targets[1:]})
            queued.append({"title": name, "job": job.get("id", "")})
        except Exception as e:
            failed.append(f"{name}: {e}")
            if "isn't running" in str(e):
                break
    where = targets[0] if len(targets) == 1 else f"{len(targets)} playlists ({', '.join(targets)})"
    return {"ok": bool(queued), "message": f"Downloading {len(queued)} song(s) into {where}. They appear in SpotVault when done.",
            "queued": queued, "failed": failed}


def call_tool(name, args):
    if name == "list_charts":
        return sources.trending_charts(args.get("country") or "IN")
    if name == "get_trending":
        limit = max(1, min(int(args.get("limit") or 25), 100))
        songs = sources.trending_songs(args.get("country") or "IN", args.get("chart") or "apple")
        return [{k: s.get(k, "") for k in ("title", "artist", "url")} for s in songs[:limit]]
    if name == "search_songs":
        q = str(args.get("query") or "").strip()
        if not q:
            raise ValueError("Give a song name to search for.")
        return [{k: r.get(k, "") for k in ("title", "artist", "duration", "url")} for r in sources.search_any(q, 10)]
    if name == "songs_like":
        return songs_like(args)
    if name == "artist_music":
        return artist_music(args)
    if name == "album_songs":
        return album_songs(args)
    if name == "playlist_songs":
        return sources.list_tracks(str(args.get("url") or ""))
    if name == "list_playlists":
        lib = library_songs({"limit": 100000})
        counts = {}
        for s in lib:
            for p in s["playlists"]:
                counts[p] = counts.get(p, 0) + 1
        return [{"name": p, "songs": counts.get(p, 0)} for p in _playlists()]
    if name == "library_songs":
        return library_songs(args)
    if name == "create_playlist":
        nm = str(args.get("name") or "").strip()
        if not nm:
            raise ValueError("Give the playlist a name.")
        out = _post("/api/playlist", {"name": nm})
        return {"ok": True, "playlist": out.get("folder", nm), "message": f"Made the playlist '{out.get('folder', nm)}'."}
    if name == "save_songs":
        return save_songs(args)
    if name == "save_song":
        song = {"url": args.get("url") or "", "title": args.get("query") or ""}
        return save_songs({"playlists": [args.get("playlist") or ""], "songs": [song]})
    raise ValueError(f"Unknown tool: {name}")


def handle(msg):
    """One JSON-RPC message in, a reply (or None for notifications) out."""
    mid = msg.get("id")
    method = msg.get("method", "")
    params = msg.get("params") or {}
    if mid is None:
        return None  # notifications (initialized, cancelled...)
    if method == "initialize":
        result = {"protocolVersion": params.get("protocolVersion") or "2025-06-18",
                  "capabilities": {"tools": {}}, "serverInfo": SERVER_INFO,
                  "instructions": "SpotVault: trending songs, search, and saving songs into the user's offline playlists."}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            out = call_tool(params.get("name", ""), params.get("arguments") or {})
            result = {"content": [{"type": "text", "text": json.dumps(out, ensure_ascii=False, indent=1)}]}
        except Exception as e:
            result = {"content": [{"type": "text", "text": str(e)}], "isError": True}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Method not found: {method}"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def _streams():
    """stdin/stdout as binary streams. The installed engine is a windowed exe,
    where Python leaves sys.stdin/stdout as None, so the raw handles the AI app
    passed in are opened directly."""
    if sys.stdin is not None and sys.stdout is not None:
        return sys.stdin.buffer, sys.stdout.buffer
    import ctypes
    import msvcrt
    k32 = ctypes.windll.kernel32
    k32.GetStdHandle.restype = ctypes.c_void_p
    fin = msvcrt.open_osfhandle(k32.GetStdHandle(-10), os.O_RDONLY | os.O_BINARY)
    fout = msvcrt.open_osfhandle(k32.GetStdHandle(-11), os.O_WRONLY | os.O_BINARY)
    return os.fdopen(fin, "rb", 0), os.fdopen(fout, "wb", 0)


def run():
    rin, rout = _streams()
    # Anything else that prints (libraries) must not mix into the protocol.
    sys.stdout = sys.stderr
    while True:
        line = rin.readline()
        if not line:
            return
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            reply = [r for r in map(handle, msg) if r] if isinstance(msg, list) else handle(msg)
        if reply:
            rout.write((json.dumps(reply, ensure_ascii=False) + "\n").encode("utf-8"))
            rout.flush()
