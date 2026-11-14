import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One song that lives on the phone.
class Track {
  final String id;
  final String path; // "<Playlist folder>/<file name>", same as on the PC
  final String title;
  final String artist;
  final String album;
  final int size;
  final int mtime;
  final double duration;
  bool hasArt;
  final int addedAt;
  /// Downloaded on the phone itself (not on the PC), so PC syncs keep it.
  final bool phoneOnly;

  Track({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.size,
    required this.mtime,
    required this.duration,
    this.hasArt = false,
    int? addedAt,
    this.phoneOnly = false,
  }) : addedAt = addedAt ?? DateTime.now().millisecondsSinceEpoch;

  String get folder => path.split('/').first;
  String get subtitle => artist.isEmpty ? (album.isEmpty ? 'Unknown artist' : album) : artist;
  Duration get length => Duration(milliseconds: (duration * 1000).round());

  factory Track.fromServer(Map<String, dynamic> j, {Track? previous}) => Track(
        id: j['id'] as String,
        path: j['path'] as String,
        title: (j['title'] as String?)?.trim().isNotEmpty == true ? j['title'] : j['file'],
        artist: (j['artist'] as String?) ?? '',
        album: (j['album'] as String?) ?? '',
        size: (j['size'] as num).toInt(),
        mtime: (j['mtime'] as num).toInt(),
        duration: ((j['duration'] as num?) ?? 0).toDouble(),
        hasArt: previous?.hasArt ?? false,
        addedAt: previous?.addedAt,
      );

  factory Track.fromJson(Map<String, dynamic> j) => Track(
        id: j['id'],
        path: j['path'],
        title: j['title'] ?? '',
        artist: j['artist'] ?? '',
        album: j['album'] ?? '',
        size: j['size'] ?? 0,
        mtime: j['mtime'] ?? 0,
        duration: (j['duration'] ?? 0).toDouble(),
        hasArt: j['hasArt'] ?? false,
        addedAt: j['addedAt'],
        phoneOnly: j['phone'] ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'size': size,
        'mtime': mtime,
        'duration': duration,
        'hasArt': hasArt,
        'addedAt': addedAt,
        if (phoneOnly) 'phone': true,
      };
}

/// A playlist mirrored from the PC (one folder on the PC = one playlist).
class PlaylistInfo {
  final String folder;
  final String title;
  final List<String> trackIds;
  bool hasCover;

  PlaylistInfo({required this.folder, required this.title, required this.trackIds, this.hasCover = false});

  factory PlaylistInfo.fromJson(Map<String, dynamic> j) => PlaylistInfo(
        folder: j['folder'],
        title: j['title'] ?? j['folder'],
        trackIds: List<String>.from(j['trackIds'] ?? const []),
        hasCover: j['hasCover'] ?? false,
      );

  Map<String, dynamic> toJson() => {'folder': folder, 'title': title, 'trackIds': trackIds, 'hasCover': hasCover};
}

enum TrackSort { pcOrder, title, artist, recentlyAdded }

/// Everything the phone remembers: songs, playlists, likes, history, settings.
/// Saved as one JSON file next to the music.
class LibraryStore extends ChangeNotifier {
  late Directory baseDir;
  late Directory musicDir;
  late Directory artDir;
  late Directory coverDir;

  final Map<String, Track> tracks = {};
  List<PlaylistInfo> playlists = [];
  final Set<String> favorites = {};
  final Map<String, int> playCounts = {};
  List<String> recent = [];

  // Connection memory
  String lastHost = '';
  String pcName = '';
  String pin = '';
  int lastSync = 0;

  // Settings
  bool mirrorDeletes = true;
  String skipUpdate = ''; // version the user chose to skip
  bool darkTheme = true;
  bool smartSleep = true; // fade out slowly before the sleep timer stops
  bool ghostQueue = true; // songs saved from search play next once they arrive
  bool useBridge = false; // download through the PC instead of on the phone

  // Vault Lab
  /// Moments: favourite spots in a song, in milliseconds, per track id.
  final Map<String, List<int>> moments = {};
  /// Rewind: listening time per day ("2026-11-13" -> ms) and per artist.
  final Map<String, int> listenDays = {};
  final Map<String, int> listenArtists = {};

  // Playback resume
  List<String> resumeQueue = [];
  int resumeIndex = 0;
  int resumePositionMs = 0;
  bool resumeShuffle = false;
  int resumeLoop = 0;

  File get _file => File('${baseDir.path}/library.json');

  Future<void> load() async {
    Directory? ext;
    if (Platform.isAndroid) {
      ext = await getExternalStorageDirectory();
    }
    baseDir = ext ?? await getApplicationDocumentsDirectory();
    musicDir = Directory('${baseDir.path}/Music');
    artDir = Directory('${baseDir.path}/art');
    coverDir = Directory('${baseDir.path}/covers');
    for (final d in [musicDir, artDir, coverDir]) {
      await d.create(recursive: true);
    }

    if (!await _file.exists()) return;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      for (final t in (j['tracks'] as List? ?? const [])) {
        final track = Track.fromJson(Map<String, dynamic>.from(t));
        tracks[track.id] = track;
      }
      playlists = [
        for (final p in (j['playlists'] as List? ?? const [])) PlaylistInfo.fromJson(Map<String, dynamic>.from(p))
      ];
      favorites.addAll(List<String>.from(j['favorites'] ?? const []));
      playCounts.addAll(Map<String, int>.from(j['playCounts'] ?? const {}));
      recent = List<String>.from(j['recent'] ?? const []);
      lastHost = j['lastHost'] ?? '';
      pcName = j['pcName'] ?? '';
      pin = j['pin'] ?? '';
      lastSync = j['lastSync'] ?? 0;
      mirrorDeletes = j['mirrorDeletes'] ?? true;
      skipUpdate = j['skipUpdate'] ?? '';
      darkTheme = j['darkTheme'] ?? true;
      smartSleep = j['smartSleep'] ?? true;
      ghostQueue = j['ghostQueue'] ?? true;
      useBridge = j['useBridge'] ?? false;
      final m = Map<String, dynamic>.from(j['moments'] ?? const {});
      m.forEach((k, v) => moments[k] = List<int>.from(v as List));
      listenDays.addAll(Map<String, int>.from(j['listenDays'] ?? const {}));
      listenArtists.addAll(Map<String, int>.from(j['listenArtists'] ?? const {}));
      final r = Map<String, dynamic>.from(j['resume'] ?? const {});
      resumeQueue = List<String>.from(r['queue'] ?? const []);
      resumeIndex = r['index'] ?? 0;
      resumePositionMs = r['position'] ?? 0;
      resumeShuffle = r['shuffle'] ?? false;
      resumeLoop = r['loop'] ?? 0;
    } catch (e) {
      debugPrint('library.json unreadable: $e');
    }
  }

  bool _saving = false;
  bool _saveAgain = false;

  /// Writes atomically (temp file + rename) so a crash never corrupts it.
  Future<void> save() async {
    if (_saving) {
      _saveAgain = true;
      return;
    }
    _saving = true;
    try {
      do {
        _saveAgain = false;
        final data = jsonEncode({
          'tracks': tracks.values.map((t) => t.toJson()).toList(),
          'playlists': playlists.map((p) => p.toJson()).toList(),
          'favorites': favorites.toList(),
          'playCounts': playCounts,
          'recent': recent,
          'lastHost': lastHost,
          'pcName': pcName,
          'pin': pin,
          'lastSync': lastSync,
          'mirrorDeletes': mirrorDeletes,
          'skipUpdate': skipUpdate,
          'darkTheme': darkTheme,
          'smartSleep': smartSleep,
          'ghostQueue': ghostQueue,
          'useBridge': useBridge,
          'moments': moments,
          'listenDays': listenDays,
          'listenArtists': listenArtists,
          'resume': {
            'queue': resumeQueue,
            'index': resumeIndex,
            'position': resumePositionMs,
            'shuffle': resumeShuffle,
            'loop': resumeLoop,
          },
        });
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(data, flush: true);
        await tmp.rename(_file.path);
      } while (_saveAgain);
    } finally {
      _saving = false;
    }
  }

  void changed({bool persist = true}) {
    notifyListeners();
    if (persist) save();
  }

  /// Adds a song the phone downloaded itself to [folder] (creating the
  /// playlist if needed). Returns the stored track.
  Track addPhoneTrack(Track t, {required String folder, required String title}) {
    final prev = tracks[t.id];
    if (prev != null) t.hasArt = prev.hasArt || t.hasArt;
    tracks[t.id] = t;
    var p = playlists.where((p) => p.folder == folder).firstOrNull;
    if (p == null) {
      p = PlaylistInfo(folder: folder, title: title, trackIds: []);
      playlists = [...playlists, p];
    }
    if (!p.trackIds.contains(t.id)) p.trackIds.add(t.id);
    changed();
    return t;
  }

  // ---------------------------------------------------------------- files
  File localFile(Track t) => File('${musicDir.path}/${t.path}');
  File artFile(Track t) => File('${artDir.path}/${t.id}.img');
  File coverFile(String folder) =>
      File('${coverDir.path}/${base64Url.encode(utf8.encode(folder)).replaceAll('=', '')}.img');

  File? artFor(Track t) => t.hasArt ? artFile(t) : null;

  File? coverFor(PlaylistInfo p) {
    if (p.hasCover) return coverFile(p.folder);
    for (final id in p.trackIds) {
      final t = tracks[id];
      if (t != null && t.hasArt) return artFile(t);
    }
    return null;
  }

  // ---------------------------------------------------------------- views
  List<Track> tracksOf(PlaylistInfo p) => [for (final id in p.trackIds) if (tracks[id] != null) tracks[id]!];

  List<Track> get allTracks => sortTracks(tracks.values.toList(), TrackSort.title);

  List<Track> get likedTracks => [for (final id in favorites) if (tracks[id] != null) tracks[id]!];

  List<Track> get recentTracks => [for (final id in recent) if (tracks[id] != null) tracks[id]!];

  List<Track> get mostPlayed {
    final list = [for (final id in playCounts.keys) if (tracks[id] != null) tracks[id]!];
    list.sort((a, b) => (playCounts[b.id] ?? 0).compareTo(playCounts[a.id] ?? 0));
    return list.take(50).toList();
  }

  List<Track> search(String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return allTracks
        .where((t) =>
            t.title.toLowerCase().contains(needle) ||
            t.artist.toLowerCase().contains(needle) ||
            t.album.toLowerCase().contains(needle))
        .toList();
  }

  static List<Track> sortTracks(List<Track> list, TrackSort sort) {
    final out = List<Track>.from(list);
    switch (sort) {
      case TrackSort.pcOrder:
        break;
      case TrackSort.title:
        out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case TrackSort.artist:
        out.sort((a, b) {
          final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      case TrackSort.recentlyAdded:
        out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return out;
  }

  // ---------------------------------------------------------------- user data
  bool isLiked(String id) => favorites.contains(id);

  void toggleLike(String id) {
    if (!favorites.remove(id)) favorites.add(id);
    changed();
  }

  void markPlayed(String id) {
    playCounts[id] = (playCounts[id] ?? 0) + 1;
    recent.remove(id);
    recent.insert(0, id);
    if (recent.length > 50) recent = recent.sublist(0, 50);
    changed();
  }

  // ---------------------------------------------------------------- Vault Lab
  List<int> momentsOf(String id) => moments[id] ?? const [];

  /// Saves a Moment; ignores one within 2 s of an existing Moment.
  bool addMoment(String id, int ms) {
    final list = moments.putIfAbsent(id, () => []);
    if (list.any((x) => (x - ms).abs() < 2000)) return false;
    list
      ..add(ms)
      ..sort();
    changed();
    return true;
  }

  void removeMoment(String id, int ms) {
    final list = moments[id];
    if (list == null) return;
    list.remove(ms);
    if (list.isEmpty) moments.remove(id);
    changed();
  }

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Adds listening time for Rewind. Saved with the next save().
  void addListening(Track t, int ms) {
    final day = dayKey(DateTime.now());
    listenDays[day] = (listenDays[day] ?? 0) + ms;
    final artist = t.artist.split(',').first.trim();
    if (artist.isNotEmpty) listenArtists[artist] = (listenArtists[artist] ?? 0) + ms;
    // Keep about a year of days.
    if (listenDays.length > 400) {
      final keys = listenDays.keys.toList()..sort();
      for (final k in keys.take(listenDays.length - 400)) {
        listenDays.remove(k);
      }
    }
  }

  /// Listening time in the last [days] days, oldest first.
  List<int> listeningByDay(int days) {
    final now = DateTime.now();
    return [
      for (var i = days - 1; i >= 0; i--) listenDays[dayKey(now.subtract(Duration(days: i)))] ?? 0,
    ];
  }

  int listeningSince(DateTime from) {
    final key = dayKey(from);
    var total = 0;
    listenDays.forEach((k, v) {
      if (k.compareTo(key) >= 0) total += v;
    });
    return total;
  }

  String? get topArtist {
    if (listenArtists.isEmpty) return null;
    return listenArtists.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  void setMirrorDeletes(bool v) {
    mirrorDeletes = v;
    changed();
  }

  /// Removes a track from the phone (file, art, likes, history).
  Future<void> deleteTrack(String id) async {
    final t = tracks.remove(id);
    if (t == null) return;
    for (final f in [localFile(t), artFile(t)]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    favorites.remove(id);
    moments.remove(id);
    playCounts.remove(id);
    recent.remove(id);
    for (final p in playlists) {
      p.trackIds.remove(id);
    }
  }

  Future<int> storageBytes() async {
    var total = 0;
    if (!await musicDir.exists()) return 0;
    await for (final e in musicDir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
