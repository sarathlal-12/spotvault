import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'library_store.dart';
import 'phone_engine.dart';
import 'sync_service.dart';

/// A song found by searching online (on the phone or through the PC).
class OnlineSong {
  final String title;
  final String artist;
  final String duration;
  final String url;
  final String thumb;

  OnlineSong({required this.title, required this.artist, required this.duration, required this.url, required this.thumb});

  factory OnlineSong.fromJson(Map<String, dynamic> j) => OnlineSong(
        title: (j['title'] as String?) ?? '',
        artist: (j['artist'] as String?) ?? '',
        duration: (j['duration'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        thumb: (j['thumb'] as String?) ?? '',
      );
}

enum DlState { connecting, downloading, copying, saved, failed }

/// One "Save" tap: the phone (or the PC) downloads the song into a playlist.
class DlJob {
  final OnlineSong song;
  final String folder;
  final String playlistTitle;
  /// Ghost Queue: play this song next as soon as it reaches the phone.
  final bool playWhenReady;
  DlState state = DlState.connecting;
  String message;
  DlJob(this.song, this.folder, this.playlistTitle, {this.playWhenReady = false, bool onPhone = true})
      : message = onPhone ? 'Starting…' : 'Connecting to your PC…';

  bool get finished => state == DlState.saved || state == DlState.failed;
}

class PcException implements Exception {
  final String message;
  PcException(this.message);
  @override
  String toString() => message;
}

/// Finds, previews and saves songs. By default the phone does it itself
/// ([PhoneEngine]); with "Use my PC" on, the SpotVault PC does the work and
/// the phone copies the file over (the original bridge). Both speak the
/// same HTTP API.
class PcLink extends ChangeNotifier {
  final LibraryStore store;
  final SyncService sync;
  PcLink(this.store, this.sync);

  String? _host;
  int _port = kHttpPort;
  final List<DlJob> jobs = [];
  Future<void> _syncChain = Future.value();

  /// Called after a download has been copied to the phone.
  Future<void> Function()? afterSync;

  /// Ghost Queue: called with the song once it is on the phone.
  Future<void> Function(Track)? onReady;

  /// True when songs are downloaded on the phone, false when the PC does it.
  bool get onPhone => !store.useBridge;

  String get _token => onPhone ? PhoneEngine.instance.token : store.pin;

  Future<void> setUseBridge(bool v) async {
    if (store.useBridge == v) return;
    store.useBridge = v;
    _host = null;
    _port = kHttpPort;
    store.changed();
    notifyListeners();
  }

  Map<String, String> get _headers => {
        'X-SpotVault-Pin': _token,
        'X-SpotVault-Device': Platform.isAndroid ? 'Android phone' : 'Phone',
      };

  String get _hostText => _port == kHttpPort ? _host! : '$_host:$_port';

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: _host, port: _port, path: path, queryParameters: q);

  Future<bool> _alive(String host, int port) async {
    try {
      final res = await http
          .get(Uri(scheme: 'http', host: host, port: port, path: '/api/status'))
          .timeout(const Duration(seconds: 4));
      return res.statusCode == 200 && jsonDecode(res.body)['app'] == 'SpotVault';
    } catch (_) {
      return false;
    }
  }

  /// Starts the phone's downloader, or finds the PC: the last one used
  /// first, then a Wi-Fi scan.
  Future<void> connect() async {
    if (onPhone) {
      final e = PhoneEngine.instance;
      try {
        await e.ensureStarted(
          musicDir: store.musicDir.path,
          artDir: '${store.baseDir.path}/engine_art',
          dataDir: store.baseDir.path,
        );
      } on EngineException catch (x) {
        throw PcException(x.message);
      }
      _host = '127.0.0.1';
      _port = e.port;
      return;
    }
    if (_host == '127.0.0.1') _host = null;
    if (store.pin.isEmpty) {
      throw PcException('Connect this phone to your PC once first: open the Sync tab, enter the address and PIN, and tap Sync now.');
    }
    if (_host != null && await _alive(_host!, _port)) return;
    if (store.lastHost.isNotEmpty) {
      final (h, p) = SyncService.parseHost(store.lastHost);
      if (await _alive(h, p)) {
        _host = h;
        _port = p;
        return;
      }
    }
    final found = await sync.discover();
    for (final pc in found) {
      if (await _alive(pc.host, pc.port)) {
        _host = pc.host;
        _port = pc.port;
        store.lastHost = _hostText;
        await store.save();
        return;
      }
    }
    _host = null;
    throw PcException('No PC found. Open SpotVault on your PC and make sure this phone is on the same Wi-Fi.');
  }

  void _checkStatus(http.Response res) {
    if (res.statusCode == 401) throw PcException('The PIN changed on your PC. Enter the new PIN in the Sync tab.');
    if (res.statusCode == 429) throw PcException('Too many wrong PINs. Wait a minute and try again.');
    if (res.statusCode != 200) {
      String msg = 'PC answered ${res.statusCode}';
      try {
        msg = (jsonDecode(utf8.decode(res.bodyBytes))['error'] as String?) ?? msg;
      } catch (_) {}
      throw PcException(msg);
    }
  }

  Future<List<OnlineSong>> search(String query) async {
    await connect();
    final res = await http
        .get(_uri('/api/search', {'q': query}), headers: _headers)
        .timeout(const Duration(seconds: 45));
    _checkStatus(res);
    final list = (jsonDecode(utf8.decode(res.bodyBytes))['results'] as List).cast<Map<String, dynamic>>();
    return [for (final j in list) OnlineSong.fromJson(j)].where((s) => s.url.isNotEmpty).toList();
  }

  /// Stream address for listening to a song before downloading it.
  Future<Uri> previewUri(OnlineSong song) async {
    await connect();
    return _uri('/api/preview', {'url': song.url, 'pin': _token});
  }

  DlJob? jobFor(OnlineSong song) {
    for (final j in jobs.reversed) {
      if (j.song.url == song.url) return j;
    }
    return null;
  }

  /// Downloads [song] into [playlist]: on the phone, or on the PC followed
  /// by a copy to the phone.
  Future<void> download(OnlineSong song, PlaylistInfo playlist, {bool playWhenReady = false}) async {
    final phone = onPhone;
    final job = DlJob(song, playlist.folder, playlist.title, playWhenReady: playWhenReady, onPhone: phone);
    jobs.add(job);
    notifyListeners();
    try {
      await connect();
      final res = await http
          .post(_uri('/api/download'),
              headers: {..._headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'url': song.url,
                'folder': playlist.folder,
                'title': song.title,
                'artist': song.artist,
                'thumb': song.thumb,
              }))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 400) {
        final err = (jsonDecode(utf8.decode(res.bodyBytes))['error'] as String?) ?? '';
        throw PcException(err.contains('not on this PC')
            ? '"${playlist.title}" is not on your PC. Pick a playlist that came from the PC, or switch off "Use my PC".'
            : err);
      }
      _checkStatus(res);
      final id = jsonDecode(res.body)['id'] as String;

      _set(job, DlState.downloading, phone ? 'Downloading…' : 'Downloading on your PC…');
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      Map<String, dynamic> j;
      while (true) {
        await Future.delayed(Duration(milliseconds: phone ? 800 : 2000));
        final r = await http.get(_uri('/api/job', {'id': id}), headers: _headers).timeout(const Duration(seconds: 15));
        _checkStatus(r);
        j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        if (j['state'] == 'done' || j['state'] == 'failed') break;
        if (DateTime.now().isAfter(deadline)) {
          throw PcException(phone ? 'This download is taking too long. Try again later.' : 'The PC is taking too long. Try again later.');
        }
      }
      if (j['state'] == 'failed') {
        final why = (j['error'] as String?) ?? '';
        throw PcException(phone ? phoneError(why) : 'The PC could not download this song.');
      }

      Track? saved;
      if (phone) {
        saved = await _addPhoneSong(j, playlist);
      } else {
        _set(job, DlState.copying, 'Copying to your phone…');
        await _syncOnce();
        if (sync.state == SyncState.error) throw PcException(sync.message);
        final path = (j['path'] as String?) ?? '';
        final arrived = path.isEmpty || store.tracks.values.any((t) => t.path == path);
        if (!arrived) throw PcException('Downloaded on the PC, but copying failed. Sync again from the Sync tab.');
        saved = store.tracks.values.where((t) => t.path == path).firstOrNull;
      }
      _set(job, DlState.saved, j['already'] == true ? 'Already in ${playlist.title}' : 'Saved to ${playlist.title}');
      if (job.playWhenReady && saved != null) {
        await onReady?.call(saved);
        _set(job, DlState.saved, 'Saved to ${playlist.title} · playing next');
      }
    } on PcException catch (e) {
      _set(job, DlState.failed, e.message);
    } on TimeoutException {
      _set(job, DlState.failed, phone ? 'The downloader stopped responding. Try again.' : 'Your PC stopped responding.');
    } catch (e) {
      _set(job, DlState.failed, 'Download failed: $e');
    }
  }

  /// Registers a song the phone's downloader saved in the music folder.
  Future<Track> _addPhoneSong(Map<String, dynamic> j, PlaylistInfo playlist) async {
    final path = j['path'] as String;
    final id = 'ph_${base64Url.encode(utf8.encode(path)).replaceAll('=', '')}';
    final t = Track(
      id: id,
      path: path,
      title: (j['title'] as String?) ?? '',
      artist: (j['artist'] as String?) ?? '',
      album: (j['album'] as String?) ?? '',
      size: ((j['size'] as num?) ?? 0).toInt(),
      mtime: ((j['mtime'] as num?) ?? 0).toInt(),
      duration: ((j['duration'] as num?) ?? 0).toDouble(),
      addedAt: store.tracks[id]?.addedAt,
      phoneOnly: true,
    );
    final art = (j['art'] as String?) ?? '';
    if (art.isNotEmpty) {
      try {
        final src = File(art);
        if (await src.exists()) {
          await src.copy(store.artFile(t).path);
          await src.delete();
          t.hasArt = true;
        }
      } catch (_) {}
    } else if (store.tracks[id]?.hasArt == true) {
      t.hasArt = true;
    }
    return store.addPhoneTrack(t, folder: playlist.folder, title: playlist.title);
  }

  /// Plain-language reason for a failed on-phone download.
  static String phoneError(String why) {
    final w = why.toLowerCase();
    if (w.contains('sign in') || w.contains('bot')) {
      return 'YouTube asked to confirm you are not a bot. Try again later, or switch on "Use my PC".';
    }
    if (w.contains('unavailable') || w.contains('private') || w.contains('removed')) {
      return 'This song is not available. Try another version.';
    }
    if (w.contains('format') || w.contains('no playable')) {
      return 'No phone-friendly audio for this one. Try another version.';
    }
    if (w.contains('network') || w.contains('timed out') || w.contains('connection') || w.contains('resolve')) {
      return 'No internet connection. Check your connection and try again.';
    }
    return why.isEmpty ? 'Download failed. Try again.' : 'Download failed: $why';
  }

  /// Runs one library sync at a time; downloads finishing together share it.
  Future<void> _syncOnce() {
    final next = _syncChain.then((_) async {
      while (sync.busy) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await sync.sync(_hostText, store.pin);
      await afterSync?.call();
    });
    _syncChain = next.catchError((_) {});
    return next;
  }

  void _set(DlJob job, DlState state, String message) {
    job.state = state;
    job.message = message;
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.finished);
    notifyListeners();
  }
}
