import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'library_store.dart';
import 'update_service.dart' show kAppVersion;

/// One timed line of lyrics.
class LyricLine {
  final Duration at;
  final String text;
  const LyricLine(this.at, this.text);
}

/// Lyrics for a song: timed lines (karaoke style) or plain text, or none.
class Lyrics {
  final List<LyricLine> lines; // empty when not timed
  final String plain;
  const Lyrics({this.lines = const [], this.plain = ''});

  bool get synced => lines.isNotEmpty;
  bool get isEmpty => lines.isEmpty && plain.trim().isEmpty;

  /// Index of the line being sung at [pos] (-1 before the first line).
  int indexAt(Duration pos) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].at <= pos) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

/// Parses LRC text ("[01:02.50] words"). Lines can carry several timestamps.
List<LyricLine> parseLrc(String lrc) {
  final out = <LyricLine>[];
  final stamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final raw in const LineSplitter().convert(lrc)) {
    final stamps = stamp.allMatches(raw).toList();
    if (stamps.isEmpty) continue;
    final text = raw.substring(stamps.last.end).trim();
    for (final m in stamps) {
      final frac = m.group(3) ?? '0';
      final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
      out.add(LyricLine(Duration(minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!), milliseconds: ms), text));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// Finds lyrics on LRCLIB (free, open lyrics database) and keeps them on the
/// phone, so a song's lyrics work offline after the first look-up.
class LyricsService {
  LyricsService(this.store);
  final LibraryStore store;
  final Map<String, Future<Lyrics>> _inFlight = {};
  final Set<String> _prefetched = {};

  static const _host = 'lrclib.net';

  Directory get _dir => Directory('${store.baseDir.path}/lyrics');

  File _file(Track t) => File('${_dir.path}/${base64Url.encode(utf8.encode(t.id)).replaceAll('=', '')}.json');

  /// Lyrics saved on the phone, or null if this song was never looked up.
  Future<Lyrics?> cached(Track t) async {
    try {
      final f = _file(t);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final none = j['none'] == true;
      final checked = (j['checked'] as num?)?.toInt() ?? 0;
      // "Not found" is retried after a week: the database keeps growing.
      if (none && DateTime.now().millisecondsSinceEpoch - checked > const Duration(days: 7).inMilliseconds) return null;
      return Lyrics(lines: parseLrc((j['synced'] as String?) ?? ''), plain: (j['plain'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Lyrics for [t]: from the phone if saved, else looked up online.
  Future<Lyrics> get(Track t) async {
    final c = await cached(t);
    if (c != null) return c;
    return _inFlight[t.id] ??= _fetch(t).whenComplete(() => _inFlight.remove(t.id));
  }

  /// Looks up lyrics in the background (after a download, or for the next song).
  void prefetch(Track t) {
    if (!_prefetched.add(t.id)) return;
    cached(t).then((c) {
      if (c == null) get(t).catchError((_) => const Lyrics());
    });
  }

  Future<Lyrics> _fetch(Track t) async {
    final title = cleanTitle(t.title);
    final artist = mainArtist(t.artist);
    Map<String, dynamic>? hit;
    try {
      hit = await _getExact(title, artist, t.duration);
      hit ??= await _search(title, artist, t.duration);
    } catch (e) {
      debugPrint('lyrics lookup failed: $e');
      rethrow; // offline: don't remember "no lyrics"
    }
    final synced = (hit?['syncedLyrics'] as String?) ?? '';
    final plain = (hit?['plainLyrics'] as String?) ?? '';
    await _save(t, synced, plain);
    return Lyrics(lines: parseLrc(synced), plain: plain);
  }

  Future<void> _save(Track t, String synced, String plain) async {
    try {
      await _dir.create(recursive: true);
      await _file(t).writeAsString(jsonEncode({
        if (synced.isNotEmpty) 'synced': synced,
        if (plain.isNotEmpty) 'plain': plain,
        if (synced.isEmpty && plain.isEmpty) 'none': true,
        'checked': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  Map<String, String> get _headers => {'User-Agent': 'SpotVault/$kAppVersion (https://spotvault-web.vercel.app)'};

  Future<Map<String, dynamic>?> _getExact(String title, String artist, double duration) async {
    if (artist.isEmpty) return null;
    final res = await http
        .get(
            Uri.https(_host, '/api/get', {
              'track_name': title,
              'artist_name': artist,
              if (duration > 0) 'duration': '${duration.round()}',
            }),
            headers: _headers)
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return _useful(j) ? j : null;
  }

  Future<Map<String, dynamic>?> _search(String title, String artist, double duration) async {
    final res = await http
        .get(Uri.https(_host, '/api/search', {'track_name': title, if (artist.isNotEmpty) 'artist_name': artist}), headers: _headers)
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(utf8.decode(res.bodyBytes)) as List).cast<Map<String, dynamic>>().where(_useful).toList();
    if (list.isEmpty) return null;
    // Closest length wins; prefer timed lyrics; skip clearly different songs.
    double score(Map<String, dynamic> j) {
      final d = ((j['duration'] as num?) ?? 0).toDouble();
      final diff = duration > 0 && d > 0 ? (d - duration).abs() : 5.0;
      return diff + ((j['syncedLyrics'] as String?)?.isNotEmpty == true ? 0 : 3);
    }

    list.sort((a, b) => score(a).compareTo(score(b)));
    final best = list.first;
    final d = ((best['duration'] as num?) ?? 0).toDouble();
    if (duration > 0 && d > 0 && (d - duration).abs() > 12) return null;
    return best;
  }

  static bool _useful(Map<String, dynamic> j) =>
      j['instrumental'] != true &&
      (((j['syncedLyrics'] as String?)?.isNotEmpty ?? false) || ((j['plainLyrics'] as String?)?.isNotEmpty ?? false));

  /// "Believer (Official Audio) [From "X"] - Remastered" -> "Believer".
  static String cleanTitle(String title) {
    var t = title;
    t = t.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '');
    t = t.replaceAll(RegExp(r'\s+-\s+(remaster(ed)?|live|radio edit|from|lyrics?|official).*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s+(feat\.?|ft\.?|featuring)\s+.*$', caseSensitive: false), '');
    return t.trim().isEmpty ? title.trim() : t.trim();
  }

  /// "Imagine Dragons, Lil Wayne" -> "Imagine Dragons".
  static String mainArtist(String artist) {
    final a = artist.split(RegExp(r',|&| x | feat\.? | ft\.? |;', caseSensitive: false)).first.trim();
    return a.replaceAll(RegExp(r'\s*-\s*Topic$'), '').trim();
  }

  @visibleForTesting
  static Lyrics fromCacheJson(Map<String, dynamic> j) =>
      Lyrics(lines: parseLrc((j['synced'] as String?) ?? ''), plain: (j['plain'] as String?) ?? '');
}

/// True when [e] means "no internet", so the UI can say so.
bool isOffline(Object e) => e is SocketException || e is TimeoutException || e is http.ClientException;
