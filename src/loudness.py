"""Measures how loud each song is, so the phone can play them at an even volume.

Runs in the background on the PC (FFmpeg's EBU R128 loudness meter), one song
at a time, and remembers results in ~/.spot_sync_cache/loudness.json keyed by
file path, size and modification time.

    gain_for(path, size, mtime) -> dB to apply (<= 0), or None if not measured yet
"""
import json
import os
import re
import subprocess
import threading

TARGET_LUFS = -14.0  # typical streaming level; louder songs are turned down to it
MIN_GAIN = -12.0

_CACHE_FILE = os.path.join(os.path.expanduser("~"), ".spot_sync_cache", "loudness.json")
_lock = threading.Lock()
_cache = None
_queue = []
_queued = set()
_cv = threading.Condition(_lock)
_started = False
_ffmpeg = None
_dirty = 0


def _load():
    global _cache
    if _cache is None:
        try:
            with open(_CACHE_FILE, encoding="utf-8") as f:
                _cache = json.load(f)
        except (OSError, ValueError):
            _cache = {}
    return _cache


def _save():
    try:
        os.makedirs(os.path.dirname(_CACHE_FILE), exist_ok=True)
        tmp = _CACHE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_cache, f)
        os.replace(tmp, _CACHE_FILE)
    except OSError:
        pass


def gain_for(path, size, mtime):
    """dB to apply for even volume, or None while not measured. Queues a measurement."""
    with _lock:
        hit = _load().get(path)
        if hit and hit[0] == size and hit[1] == int(mtime):
            lufs = hit[2]
            if lufs is None:
                return 0.0
            return round(max(MIN_GAIN, min(0.0, TARGET_LUFS - lufs)), 2)
        if path not in _queued:
            _queued.add(path)
            _queue.append((path, size, int(mtime)))
            _cv.notify()
    return None


def measure(path, ffmpeg):
    """Integrated loudness in LUFS, or None."""
    try:
        r = subprocess.run(
            [ffmpeg, "-hide_banner", "-nostats", "-i", path, "-vn", "-af", "ebur128=framelog=verbose", "-f", "null", "-"],
            capture_output=True, text=True, timeout=180,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        m = re.findall(r"I:\s*(-?\d+(?:\.\d+)?)\s*LUFS", r.stderr)
        if r.returncode != 0 or not m:
            return None
        v = float(m[-1])
        return v if v < -1 else None  # 0.0 means nothing was measured
    except Exception:
        return None


def _worker():
    global _dirty
    while True:
        with _cv:
            while not _queue:
                if _dirty:
                    _save()
                    _dirty = 0
                _cv.wait()
            path, size, mtime = _queue.pop(0)
        lufs = measure(path, _ffmpeg) if os.path.exists(path) else None
        with _lock:
            _queued.discard(path)
            _load()[path] = [size, mtime, lufs]
            _dirty += 1
            if _dirty >= 20:
                _save()
                _dirty = 0


def start(ffmpeg_path):
    """Start measuring in the background (call once FFmpeg is known)."""
    global _started, _ffmpeg
    if _started or not ffmpeg_path:
        return
    _ffmpeg = ffmpeg_path
    _started = True
    t = threading.Thread(target=_worker, daemon=True)
    t.start()
