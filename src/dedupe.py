"""One copy per song: songs saved in several playlists share one file on disk.

Windows (NTFS) hard links let the same file sit in several folders while it is
stored once. Delete it from one playlist and it stays in the others; phones,
players and Explorer see a normal file in each folder.

- Exact copies (same bytes) are linked automatically.
- Near copies (same song, different download) are listed for the user to
  approve: the better copy is kept, the other goes to the Recycle Bin and a
  link to the kept copy takes its place.
"""
import hashlib
import os
import re

AUDIO = (".m4a", ".mp3", ".opus", ".ogg", ".flac", ".wav", ".webm")
_JUNK = re.compile(r"\b(official|video|audio|lyrics?|lyrical|full song|hd|4k|from|feat|ft|remastered|remaster)\b")


def _norm(text):
    s = text.lower()
    s = re.sub(r"[\(\[].*?[\)\]]", " ", s)
    s = _JUNK.sub(" ", s)
    return " ".join(re.findall(r"\w+", s))


def _meta(path):
    """(title, artist, seconds, bitrate) from the tags, falling back to the file name."""
    stem = os.path.splitext(os.path.basename(path))[0]
    artist, title = stem.split(" - ", 1) if " - " in stem else ("", stem)
    secs = rate = 0
    try:
        import mutagen
        audio = mutagen.File(path, easy=True)
        if audio is not None:
            tags = audio.tags or {}
            t, a = tags.get("title"), tags.get("artist")
            title = (t[0] if isinstance(t, list) and t else t) or title
            artist = (a[0] if isinstance(a, list) and a else a) or artist
            if getattr(audio, "info", None) is not None:
                secs = float(getattr(audio.info, "length", 0) or 0)
                rate = int(getattr(audio.info, "bitrate", 0) or 0)
    except Exception:
        pass
    return str(title), str(artist), secs, rate


def _hash(path, _cache={}):
    st = os.stat(path)
    key = (path, st.st_size, st.st_mtime_ns)
    if key not in _cache:
        h = hashlib.sha1()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        _cache[key] = h.hexdigest()
    return _cache[key]


def _files(master, folders):
    out = []
    for folder in folders:
        d = os.path.join(master, folder)
        try:
            for e in os.scandir(d):
                if e.is_file() and e.name.lower().endswith(AUDIO):
                    st = os.stat(e.path)  # DirEntry.stat() has no inode number on Windows
                    out.append({"path": e.path, "folder": folder, "name": e.name, "size": st.st_size,
                                "inode": (st.st_dev, st.st_ino)})
        except OSError:
            pass
    return out


def scan(master, folders):
    """Finds songs stored more than once across the playlists.

    Returns {"exact": [[file, ...], ...], "review": [{"files": [...], "keep": path}], "exact_bytes": n}
    Each file: {path, folder, name, size, seconds, bitrate}.
    """
    files = _files(master, folders)
    # Group by song: the title words, ignoring "(Official Audio)" and the like.
    groups = {}
    for f in files:
        title, artist, secs, rate = _meta(f["path"])
        f.update(seconds=round(secs, 1), bitrate=rate // 1000, title=title, artist=artist)
        key = _norm(title) or _norm(os.path.splitext(f["name"])[0])
        if key:
            groups.setdefault(key, []).append(f)

    exact, review, exact_bytes = [], [], 0
    for members in groups.values():
        # Files that already share one copy count once.
        by_inode = {}
        for f in members:
            by_inode.setdefault(f["inode"], f)
        uniq = list(by_inode.values())
        if len(uniq) < 2:
            continue
        # Exact copies: same size and same bytes.
        by_hash = {}
        for f in uniq:
            same_size = [g for g in uniq if g is not f and g["size"] == f["size"]]
            key = _hash(f["path"]) if same_size else f"size:{f['path']}"
            by_hash.setdefault(key, []).append(f)
        reps = []
        for copies in by_hash.values():
            if len(copies) > 1:
                exact.append([_public(c) for c in copies])
                exact_bytes += sum(c["size"] for c in copies[1:])
            reps.append(copies[0])
        if len(reps) < 2:
            continue
        # Near copies: different files of what looks like the same song. They must
        # be about as long and share an artist name, so remixes and covers stay apart.
        base = reps[0]
        near = [base] + [r for r in reps[1:] if _same_song(base, r)]
        if len(near) > 1:
            best = max(near, key=lambda r: (r["bitrate"], r["size"]))
            review.append({"files": [_public(r) for r in near], "keep": best["path"],
                           "title": best["title"], "artist": best["artist"]})
    return {"exact": exact, "review": review, "exact_bytes": exact_bytes}


def _same_song(a, b):
    if a["seconds"] and b["seconds"] and abs(a["seconds"] - b["seconds"]) > 3:
        return False
    wa = {w for w in _norm(a["artist"]).split() if len(w) > 2}
    wb = {w for w in _norm(b["artist"]).split() if len(w) > 2}
    return not wa or not wb or bool(wa & wb)


def _public(f):
    return {k: f.get(k) for k in ("path", "folder", "name", "size", "seconds", "bitrate")}


def link(keep, other, recycle=None):
    """Replaces `other` with a hard link to `keep`. Returns the new path or raises OSError.

    Same bytes: the link keeps other's name. Different bytes (a near copy the user
    approved): other goes to the Recycle Bin and the link takes keep's name.
    """
    keep, other = os.path.abspath(keep), os.path.abspath(other)
    if os.path.samefile(keep, other):
        return other
    same = os.path.getsize(keep) == os.path.getsize(other) and _hash(keep) == _hash(other)
    folder = os.path.dirname(other)
    target = other if same else os.path.join(folder, os.path.basename(keep))
    if not same and os.path.exists(target) and not os.path.samefile(target, other):
        # Another file of that name is already in this folder: keep other's name.
        target = other
    tmp = os.path.join(folder, f".svlink-{os.getpid()}-{os.path.basename(keep)}")
    os.link(keep, tmp)
    try:
        if same:
            os.replace(tmp, other)
        else:
            if recycle is not None:
                recycle(other)
            elif os.path.exists(other):
                os.remove(other)
            os.replace(tmp, target)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    return target


def link_exact(master, folders, found=None):
    """Links every exact copy. Returns (songs linked, bytes freed, errors)."""
    found = found or scan(master, folders)
    n, freed, errors = 0, 0, []
    for copies in found["exact"]:
        keep = copies[0]["path"]
        for c in copies[1:]:
            try:
                link(keep, c["path"])
                n += 1
                freed += c["size"]
            except OSError as e:
                errors.append(f"{c['name']}: {e.strerror or e}")
    return n, freed, errors


def place(path, folders):
    """Shows an already saved song in more playlist folders, stored once (save to several playlists)."""
    n = 0
    if not path or not os.path.isfile(path):
        return n
    for folder in folders:
        target = os.path.join(folder, os.path.basename(path))
        try:
            os.makedirs(folder, exist_ok=True)
            if os.path.exists(target):
                continue
            try:
                os.link(path, target)
            except OSError:
                import shutil
                shutil.copy2(path, target)  # another drive: a copy is the only way
            n += 1
        except OSError:
            pass
    return n
