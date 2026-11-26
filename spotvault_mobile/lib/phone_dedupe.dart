// Duplicate songs on the phone, cleaned up on the phone itself (no PC needed).
//
// A phone song is one file plus one entry; playlists only point at entries. So
// "one copy per song" here means: keep one entry, point every playlist at it,
// and delete the other files. Only songs downloaded on the phone are touched:
// songs from the PC are cleaned up by the PC, and the next PC sync would bring
// a removed one back.
import 'dart:io';
import 'dart:math' as math;

import 'app_state.dart';
import 'library_store.dart';

/// The same song stored more than once.
class DupeGroup {
  final List<Track> copies;

  /// Identical files: safe to merge without asking.
  final bool exact;

  /// The copy that stays (the best quality one, unless the user picks another).
  Track keep;

  DupeGroup(this.copies, {required this.exact, required this.keep});

  int get freeBytes => copies.where((t) => t.id != keep.id).fold(0, (s, t) => s + t.size);
}

/// Title without "(feat. …)", "[Official Video]", "- Remastered" and the like.
String normTitle(String s) {
  var t = s.toLowerCase();
  t = t.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]|\{[^}]*\}'), ' ');
  t = t.replaceAll(RegExp(r'\b(official|audio|video|lyrics?|lyrical|hd|hq|4k|remaster(ed)?|full song|visualizer)\b'), ' ');
  t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return t.trim().replaceAll(RegExp(r'\s+'), ' ');
}

Set<String> _artistWords(String a) => {
      for (final w in a.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        if (w.length > 1 && w != 'the' && w != 'feat' && w != 'ft' && w != 'and') w,
    };

/// Whether two songs are the same song (title, artist and length agree).
bool sameSong(String titleA, String artistA, double secsA, String titleB, String artistB, double secsB) {
  final a = normTitle(titleA), b = normTitle(titleB);
  if (a.isEmpty || a != b) return false;
  final wa = _artistWords(artistA), wb = _artistWords(artistB);
  if (wa.isNotEmpty && wb.isNotEmpty && wa.intersection(wb).isEmpty) return false;
  if (secsA > 0 && secsB > 0 && (secsA - secsB).abs() > 3) return false;
  return true;
}

/// Same size and the same first and last 64 KB: the same file.
Future<bool> _identical(File a, File b) async {
  final la = await a.length(), lb = await b.length();
  if (la != lb) return false;
  const chunk = 64 * 1024;
  Future<List<int>> read(File f, int at) async {
    final r = await f.open();
    try {
      await r.setPosition(at);
      return await r.read(math.min(chunk, la - at));
    } finally {
      await r.close();
    }
  }

  for (final at in {0, math.max(0, la - chunk)}) {
    final x = await read(a, at), y = await read(b, at);
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
  }
  return true;
}

/// Best quality first: higher bitrate (size per second), then bigger file.
Track _best(List<Track> l) => (List.of(l)
      ..sort((a, b) {
        double rate(Track t) => t.duration > 0 ? t.size / t.duration : 0;
        final r = rate(b).compareTo(rate(a));
        return r != 0 ? r : b.size.compareTo(a.size);
      }))
    .first;

/// Finds songs downloaded on the phone that are stored more than once.
Future<List<DupeGroup>> findPhoneDupes([LibraryStore? s]) async {
  final st = s ?? store;
  final songs = [
    for (final t in st.tracks.values)
      if (t.phoneOnly && st.localFile(t).existsSync()) t,
  ];
  final byTitle = <String, List<Track>>{};
  for (final t in songs) {
    final k = normTitle(t.title);
    if (k.isNotEmpty) byTitle.putIfAbsent(k, () => []).add(t);
  }
  final groups = <DupeGroup>[];
  for (final same in byTitle.values) {
    if (same.length < 2) continue;
    final left = List.of(same);
    while (left.isNotEmpty) {
      final first = left.removeAt(0);
      final cluster = [first];
      left.removeWhere((t) {
        final hit = cluster.any((c) => sameSong(c.title, c.artist, c.duration, t.title, t.artist, t.duration));
        if (hit) cluster.add(t);
        return hit;
      });
      if (cluster.length < 2) continue;
      var exact = true;
      for (final t in cluster.skip(1)) {
        if (!await _identical(st.localFile(cluster.first), st.localFile(t))) {
          exact = false;
          break;
        }
      }
      groups.add(DupeGroup(cluster, exact: exact, keep: _best(cluster)));
    }
  }
  groups.sort((a, b) => b.freeBytes.compareTo(a.freeBytes));
  return groups;
}

/// Keeps [g.keep]: every playlist, like and play count moves to it, and the
/// other copies are deleted. Returns the bytes freed.
Future<int> mergeDupes(DupeGroup g, [LibraryStore? s]) async {
  final st = s ?? store;
  final keep = g.keep.id;
  var freed = 0;
  for (final o in g.copies) {
    if (o.id == keep) continue;
    for (final p in st.playlists) {
      final i = p.trackIds.indexOf(o.id);
      if (i < 0) continue;
      if (p.trackIds.contains(keep)) {
        p.trackIds.removeAt(i);
      } else {
        p.trackIds[i] = keep; // same place in the playlist
      }
    }
    if (st.favorites.contains(o.id)) st.favorites.add(keep);
    final plays = st.playCounts[o.id];
    if (plays != null) st.playCounts[keep] = (st.playCounts[keep] ?? 0) + plays;
    final r = st.recent.indexOf(o.id);
    if (r >= 0) st.recent[r] = keep;
    st.recent = [
      for (final (i, id) in st.recent.indexed)
        if (st.recent.indexOf(id) == i) id,
    ];
    if (!st.tracks[keep]!.hasArt && o.hasArt && st.artFile(o).existsSync()) {
      try {
        st.artFile(o).copySync(st.artFile(st.tracks[keep]!).path);
        st.tracks[keep]!.hasArt = true;
      } catch (_) {}
    }
    freed += o.size;
    // Phone-only songs are the app's own files (deleteTrack leaves files alone on Windows).
    try {
      final f = st.localFile(o);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await st.deleteTrack(o.id);
  }
  st.changed();
  return freed;
}

/// A song already on the phone that matches [title] by [artist] (for "save"
/// without downloading it again). [secs] is 0 when unknown.
Track? songOnPhone(String title, String artist, double secs, [LibraryStore? s]) {
  final st = s ?? store;
  for (final t in st.tracks.values) {
    if (sameSong(title, artist, secs, t.title, t.artist, t.duration) && st.localFile(t).existsSync()) return t;
  }
  return null;
}
