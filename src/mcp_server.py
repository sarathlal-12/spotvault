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
import urllib.request

import sources

PORT = 50505
SERVER_INFO = {"name": "spotvault", "version": "2.3.0"}

TOOLS = [
    {
        "name": "list_charts",
        "description": "List the music charts available for a country (Apple Music Top 50 plus YouTube Music lists "
                       "such as top songs and, in India, Hindi, Tamil, Telugu, Punjabi charts).",
        "inputSchema": {"type": "object", "properties": {
            "country": {"type": "string", "description": "Two-letter country code, e.g. IN, US, GB. Default IN."}}},
    },
    {
        "name": "get_trending",
        "description": "Get today's trending songs for a country and chart. Returns title, artist and (for YouTube "
                       "Music charts) a link.",
        "inputSchema": {"type": "object", "properties": {
            "country": {"type": "string", "description": "Two-letter country code. Default IN."},
            "chart": {"type": "string", "description": "Chart id from list_charts. Default 'apple' (Apple Music Top 50)."},
            "limit": {"type": "integer", "description": "How many songs (1-100). Default 25."}}},
    },
    {
        "name": "search_songs",
        "description": "Search for songs online (YouTube Music first, then SoundCloud and YouTube), clean studio "
                       "versions preferred.",
        "inputSchema": {"type": "object", "required": ["query"], "properties": {
            "query": {"type": "string", "description": "Song name and artist."}}},
    },
    {
        "name": "list_playlists",
        "description": "List the user's SpotVault playlists on this PC.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "save_song",
        "description": "Download a song into one of the user's SpotVault playlists. Give a link from search_songs or "
                       "get_trending, or just the song name and artist. SpotVault must be open on this PC.",
        "inputSchema": {"type": "object", "required": ["playlist"], "properties": {
            "playlist": {"type": "string", "description": "Playlist folder name, from list_playlists."},
            "url": {"type": "string", "description": "Song link (optional)."},
            "query": {"type": "string", "description": "Song name and artist, used when there is no link."}}},
    },
]


def _config():
    try:
        with open("library_config.json", "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _playlists():
    return [p.get("folder", "") for p in _config().get("playlists") or [] if p.get("folder")]


def _post(path, body):
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
    if name == "list_playlists":
        return _playlists()
    if name == "save_song":
        playlist = str(args.get("playlist") or "").strip()
        if playlist not in _playlists():
            raise ValueError(f"No playlist called '{playlist}'. Use list_playlists to see the names.")
        url, title = str(args.get("url") or "").strip(), ""
        if not url:
            q = str(args.get("query") or "").strip()
            if not q:
                raise ValueError("Give a song link (url) or a song name (query).")
            hits = sources.search_any(q, 3)
            if not hits:
                raise ValueError(f"No copy of '{q}' found online.")
            url, title = hits[0].get("url", ""), hits[0].get("title", "")
        job = _post("/api/download", {"url": url, "folder": playlist, "title": title})
        return {"ok": True, "message": f"Downloading into '{playlist}'. It appears in SpotVault when done.", "job": job.get("id", "")}
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
