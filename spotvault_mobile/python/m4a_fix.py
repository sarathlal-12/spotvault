"""Turn a fragmented MP4 audio file into a normal one, in pure Python.

Phones have no FFmpeg, so yt-dlp saves YouTube's DASH audio and SoundCloud's
streamed AAC exactly as they arrive: fragmented MP4 (moov + many moof/mdat
pairs). iPhone plays that fine, but Android's player only sees the first
fragment (a 10-second song). FFmpeg's fix on the PC rewrites such files into a
plain MP4 with one sample table; this does the same for a single audio track.

    defragment(path) -> True if the file was rewritten.
"""
import os
import struct

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"mvex", b"moof", b"traf", b"dinf", b"edts", b"udta"}


def _boxes(data, start=0, end=None):
    """Yield (type, box_start, payload_start, box_end) for boxes in data[start:end]."""
    end = len(data) if end is None else end
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack(">I4s", data[pos:pos + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header or pos + size > end:
            break
        yield typ, pos, pos + header, pos + size
        pos += size


def _find(data, start, end, typ):
    for t, b, p, e in _boxes(data, start, end):
        if t == typ:
            return b, p, e
    return None


def _box(typ, payload):
    return struct.pack(">I4s", 8 + len(payload), typ) + payload


def _full(typ, version, flags, payload):
    return _box(typ, struct.pack(">I", (version << 24) | flags) + payload)


def _set_duration(payload, kind, duration):
    """Patch the duration field of an mvhd / tkhd / mdhd payload."""
    p = bytearray(payload)
    v = p[0]
    if kind in (b"mvhd", b"mdhd"):
        off = 4 + (16 if v == 1 else 8) + 4  # after version/flags, creation+modification, timescale
    else:  # tkhd: creation, modification, track_ID, reserved
        off = 4 + (16 if v == 1 else 8) + 8
    if v == 1:
        p[off:off + 8] = struct.pack(">Q", duration)
    else:
        p[off:off + 4] = struct.pack(">I", min(duration, 0xFFFFFFFF))
    return bytes(p)


def _timescale(payload):
    v = payload[0]
    off = 4 + (16 if v == 1 else 8)
    return struct.unpack(">I", payload[off:off + 4])[0]


def defragment(path):
    with open(path, "rb") as f:
        data = f.read()
    top = list(_boxes(data))
    moov = next(((b, p, e) for t, b, p, e in top if t == b"moov"), None)
    if not moov or not _find(data, moov[1], moov[2], b"mvex"):
        return False  # already a normal MP4
    # A plain audio-file brand (DASH files say "dash", which some players treat specially).
    ftyp = _box(b"ftyp", b"M4A \x00\x00\x02\x00M4A mp42isom")

    traks = [(b, p, e) for t, b, p, e in _boxes(data, moov[1], moov[2]) if t == b"trak"]
    if len(traks) != 1:
        return False  # only plain single-track audio is handled
    trak = traks[0]
    mvex = _find(data, moov[1], moov[2], b"mvex")
    trex = _find(data, mvex[1], mvex[2], b"trex")
    d_dur = d_size = 0
    if trex:
        _, _, _, d_dur, d_size, _ = struct.unpack(">IIIIII", data[trex[1]:trex[1] + 24])

    # Collect every sample: (duration, size, absolute offset).
    samples = []
    for t, mb, mp, me in top:
        if t != b"moof":
            continue
        for tt, tb, tp, te in _boxes(data, mp, me):
            if tt != b"traf":
                continue
            tfhd = _find(data, tp, te, b"tfhd")
            vf = struct.unpack(">I", data[tfhd[1]:tfhd[1] + 4])[0]
            flags = vf & 0xFFFFFF
            q = tfhd[1] + 8  # version/flags + track_ID
            base = mb
            dur, size = d_dur, d_size
            if flags & 0x1:
                base = struct.unpack(">Q", data[q:q + 8])[0]
                q += 8
            if flags & 0x2:
                q += 4
            if flags & 0x8:
                dur = struct.unpack(">I", data[q:q + 4])[0]
                q += 4
            if flags & 0x10:
                size = struct.unpack(">I", data[q:q + 4])[0]
                q += 4
            for rt, rb, rp, re in _boxes(data, tp, te):
                if rt != b"trun":
                    continue
                vf = struct.unpack(">I", data[rp:rp + 4])[0]
                rflags = vf & 0xFFFFFF
                count = struct.unpack(">I", data[rp + 4:rp + 8])[0]
                q = rp + 8
                offset = base
                if rflags & 0x1:
                    offset = base + struct.unpack(">i", data[q:q + 4])[0]
                    q += 4
                if rflags & 0x4:
                    q += 4
                for _ in range(count):
                    sd, ss = dur, size
                    if rflags & 0x100:
                        sd = struct.unpack(">I", data[q:q + 4])[0]
                        q += 4
                    if rflags & 0x200:
                        ss = struct.unpack(">I", data[q:q + 4])[0]
                        q += 4
                    if rflags & 0x400:
                        q += 4
                    if rflags & 0x800:
                        q += 4
                    samples.append((sd, ss, offset))
                    offset += ss
    if not samples:
        return False

    media = b"".join(data[o:o + s] for _, s, o in samples)
    total = sum(d for d, _, _ in samples)

    mvhd = _find(data, moov[1], moov[2], b"mvhd")
    mvhd_payload = data[mvhd[1]:mvhd[2]]
    mdia = _find(data, trak[1], trak[2], b"mdia")
    mdhd = _find(data, mdia[1], mdia[2], b"mdhd")
    mdhd_payload = data[mdhd[1]:mdhd[2]]
    media_ts = _timescale(mdhd_payload) or 1
    movie_ts = _timescale(mvhd_payload) or media_ts
    movie_total = total * movie_ts // media_ts

    minf = _find(data, mdia[1], mdia[2], b"minf")
    stbl = _find(data, minf[1], minf[2], b"stbl")
    stsd = _find(data, stbl[1], stbl[2], b"stsd")

    # Sample table: durations (run-length), sizes, one chunk holding everything.
    runs = []
    for d, _, _ in samples:
        if runs and runs[-1][1] == d:
            runs[-1][0] += 1
        else:
            runs.append([1, d])
    stts = _full(b"stts", 0, 0, struct.pack(">I", len(runs)) + b"".join(struct.pack(">II", c, d) for c, d in runs))
    stsc = _full(b"stsc", 0, 0, struct.pack(">IIII", 1, 1, len(samples), 1))
    stsz = _full(b"stsz", 0, 0, struct.pack(">II", 0, len(samples)) + b"".join(struct.pack(">I", s) for _, s, _ in samples))

    def build(chunk_offset):
        stco = _full(b"stco", 0, 0, struct.pack(">II", 1, chunk_offset))
        new_stbl = _box(b"stbl", data[stsd[0]:stsd[2]] + stts + stsc + stsz + stco)
        minf_kids = b"".join(new_stbl if t == b"stbl" else data[b:e] for t, b, p, e in _boxes(data, minf[1], minf[2]))
        mdia_kids = b""
        for t, b, p, e in _boxes(data, mdia[1], mdia[2]):
            if t == b"mdhd":
                mdia_kids += _box(b"mdhd", _set_duration(mdhd_payload, b"mdhd", total))
            elif t == b"minf":
                mdia_kids += _box(b"minf", minf_kids)
            else:
                mdia_kids += data[b:e]
        trak_kids = b""
        for t, b, p, e in _boxes(data, trak[1], trak[2]):
            if t == b"tkhd":
                trak_kids += _box(b"tkhd", _set_duration(data[p:e], b"tkhd", movie_total))
            elif t == b"mdia":
                trak_kids += _box(b"mdia", mdia_kids)
            elif t == b"edts":
                continue  # edit lists from the stream no longer apply
            else:
                trak_kids += data[b:e]
        moov_kids = b""
        for t, b, p, e in _boxes(data, moov[1], moov[2]):
            if t == b"mvhd":
                moov_kids += _box(b"mvhd", _set_duration(mvhd_payload, b"mvhd", movie_total))
            elif t == b"trak":
                moov_kids += _box(b"trak", trak_kids)
            elif t == b"mvex":
                continue
            else:
                moov_kids += data[b:e]
        return _box(b"moov", moov_kids)

    # Two passes: the chunk offset depends on the moov size, which doesn't change.
    moov_box = build(0)
    mdat_header = 8 if len(media) + 8 <= 0xFFFFFFFF else 16
    moov_box = build(len(ftyp) + len(moov_box) + mdat_header)
    if mdat_header == 8:
        mdat = struct.pack(">I4s", 8 + len(media), b"mdat")
    else:
        mdat = struct.pack(">I4sQ", 1, b"mdat", 16 + len(media))

    tmp = path + ".defrag"
    with open(tmp, "wb") as f:
        f.write(ftyp)
        f.write(moov_box)
        f.write(mdat)
        f.write(media)
    os.replace(tmp, path)
    return True
