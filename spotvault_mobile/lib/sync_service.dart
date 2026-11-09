import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'library_store.dart';

const int kHttpPort = 50505;
const int kDiscoveryPort = 50506;
const String kDiscoveryMagic = 'SPOTVAULT_DISCOVER_V1';
const int kParallelDownloads = 3;

class FoundPc {
  final String host;
  final int port;
  final String name;
  FoundPc(this.host, this.port, this.name);
}

enum SyncState { idle, connecting, syncing, done, error, cancelled }

class SyncException implements Exception {
  final String message;
  SyncException(this.message);
  @override
  String toString() => message;
}

/// Talks to the SpotVault Windows app and mirrors its library onto the phone.
class SyncService extends ChangeNotifier {
  final LibraryStore store;
  SyncService(this.store);

  SyncState state = SyncState.idle;
  String message = '';
  int filesTotal = 0;
  int filesDone = 0;
  int filesFailed = 0;
  int bytesTotal = 0;
  int bytesDone = 0;
  int removed = 0;
  final Set<String> active = {};

  bool scanning = false;
  List<FoundPc> found = [];

  bool _cancel = false;
  http.Client? _client;

  bool get busy => state == SyncState.connecting || state == SyncState.syncing;
  double get progress => bytesTotal == 0 ? (filesTotal == 0 ? 0 : filesDone / filesTotal) : bytesDone / bytesTotal;

  // -------------------------------------------------------------- discovery
  /// Broadcasts on the Wi-Fi and collects SpotVault PCs that answer.
  Future<List<FoundPc>> discover({Duration wait = const Duration(seconds: 3)}) async {
    if (scanning) return found;
    scanning = true;
    found = [];
    notifyListeners();

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      // Directed broadcast (x.y.z.255) works on routers that drop 255.255.255.255.
      for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in nic.addresses) {
          final p = a.address.split('.');
          if (p.length == 4 && !a.isLoopback) targets.add(InternetAddress('${p[0]}.${p[1]}.${p[2]}.255'));
        }
      }

      final seen = <String>{};
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        try {
          final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (j['app'] != 'SpotVault') return;
          final host = dg.address.address;
          if (seen.add(host)) {
            found = [...found, FoundPc(host, (j['port'] as num?)?.toInt() ?? kHttpPort, j['name'] ?? host)];
            notifyListeners();
          }
        } catch (_) {}
      });

      final payload = utf8.encode(kDiscoveryMagic);
      for (var i = 0; i < 3; i++) {
        for (final t in targets) {
          try {
            socket.send(payload, t, kDiscoveryPort);
          } catch (_) {}
        }
        await Future.delayed(wait ~/ 3);
      }
      await sub.cancel();
    } catch (e) {
      debugPrint('discovery failed: $e');
    } finally {
      socket?.close();
      scanning = false;
      notifyListeners();
    }
    return found;
  }

  // -------------------------------------------------------------- http
  static (String, int) parseHost(String input) {
    var s = input.trim().replaceFirst(RegExp(r'^https?://'), '');
    s = s.split('/').first;
    final idx = s.lastIndexOf(':');
    if (idx > 0) {
      final port = int.tryParse(s.substring(idx + 1));
      if (port != null) return (s.substring(0, idx), port);
    }
    return (s, kHttpPort);
  }

  Uri _uri(String host, int port, String path, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: q);

  Map<String, String> _headers(String pin) => {
        'X-SpotVault-Pin': pin,
        'X-SpotVault-Device': Platform.isAndroid ? 'Android phone' : 'Phone',
      };

  Future<Map<String, dynamic>> _getJson(String host, int port, String path, String pin) async {
    final res = await _client!
        .get(_uri(host, port, path), headers: _headers(pin))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode == 401) throw SyncException('Wrong PIN. Check the Phone Sync window on your PC.');
    if (res.statusCode == 429) throw SyncException('Too many wrong PINs. Wait a minute and try again.');
    if (res.statusCode != 200) throw SyncException('PC answered ${res.statusCode}.');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  // -------------------------------------------------------------- sync
  void cancel() {
    if (!busy) return;
    _cancel = true;
    message = 'Stopping…';
    notifyListeners();
  }

  Future<void> sync(String hostInput, String pin) async {
    if (busy) return;
    final (host, port) = parseHost(hostInput);
    if (host.isEmpty) {
      _fail('Enter the address shown on your PC.');
      return;
    }

    _cancel = false;
    state = SyncState.connecting;
    message = 'Connecting to $host…';
    filesTotal = filesDone = filesFailed = bytesTotal = bytesDone = removed = 0;
    active.clear();
    notifyListeners();

    _client = http.Client();
    _keepAwake(true);
    Map<String, dynamic>? lib;
    try {
      try {
        final status = await _client!.get(_uri(host, port, '/api/status')).timeout(const Duration(seconds: 6));
        final j = jsonDecode(status.body);
        if (j['app'] != 'SpotVault') throw SyncException('That address is not a SpotVault PC.');
      } on SyncException {
        rethrow;
      } catch (_) {
        throw SyncException(
            "Can't reach $host:$port. Check both devices are on the same Wi-Fi and SpotVault is open on the PC.");
      }

      message = 'Reading library…';
      notifyListeners();
      lib = await _getJson(host, port, '/api/library', pin);

      store.lastHost = port == kHttpPort ? host : '$host:$port';
      store.pin = pin;
      store.pcName = lib['name'] ?? host;
      await store.save();

      await _mirror(host, port, pin, lib);

      if (_cancel) {
        state = SyncState.cancelled;
        message = 'Stopped. $filesDone of $filesTotal songs copied. Sync again to resume.';
      } else {
        store.lastSync = DateTime.now().millisecondsSinceEpoch;
        state = SyncState.done;
        final parts = <String>[
          filesTotal == 0 ? 'Already up to date' : '$filesDone new songs',
          if (removed > 0) '$removed removed',
          if (filesFailed > 0) '$filesFailed failed',
        ];
        message = parts.join(' · ');
      }
    } on SyncException catch (e) {
      _fail(e.message);
    } on TimeoutException {
      _fail('The PC stopped responding.');
    } catch (e) {
      _fail('Sync failed: $e');
    } finally {
      _client?.close();
      _client = null;
      active.clear();
      _keepAwake(false);
      store.changed();
      notifyListeners();
    }
  }

  /// Keeps the screen on while copying so Android doesn't pause the transfer.
  void _keepAwake(bool on) {
    try {
      WakelockPlus.toggle(enable: on).catchError((_) {});
    } catch (_) {}
  }

  void _fail(String msg) {
    state = SyncState.error;
    message = msg;
    notifyListeners();
  }

  Future<void> _mirror(String host, int port, String pin, Map<String, dynamic> lib) async {
    final remotePlaylists = (lib['playlists'] as List).cast<Map<String, dynamic>>();

    // 1. Work out what is new or changed.
    final remoteTracks = <String, Track>{};
    final toFetch = <Track>[];
    for (final pl in remotePlaylists) {
      for (final raw in (pl['tracks'] as List).cast<Map<String, dynamic>>()) {
        final prev = store.tracks[raw['id']];
        final t = Track.fromServer(raw, previous: prev);
        remoteTracks[t.id] = t;
        final f = store.localFile(t);
        final upToDate = prev != null && prev.size == t.size && prev.mtime == t.mtime && f.existsSync() && f.lengthSync() == t.size;
        if (!upToDate) toFetch.add(t);
      }
    }
    filesTotal = toFetch.length;
    bytesTotal = toFetch.fold(0, (s, t) => s + t.size);

    // 2. Playlist covers (small, fetch first so the library looks right early).
    final newPlaylists = <PlaylistInfo>[];
    for (final pl in remotePlaylists) {
      final folder = pl['folder'] as String;
      var hasCover = false;
      if (pl['has_cover'] == true) {
        hasCover = await _fetchSmall(host, port, pin, '/api/cover', {'folder': folder}, store.coverFile(folder));
      }
      newPlaylists.add(PlaylistInfo(
        folder: folder,
        title: pl['title'] ?? folder,
        trackIds: [for (final t in (pl['tracks'] as List)) t['id'] as String],
        hasCover: hasCover,
      ));
    }

    // 3. Copy songs, a few at a time.
    state = SyncState.syncing;
    message = filesTotal == 0 ? 'Checking…' : 'Copying $filesTotal songs (${formatBytes(bytesTotal)})';
    notifyListeners();

    final queue = List<Track>.from(toFetch);
    Future<void> worker() async {
      while (queue.isNotEmpty && !_cancel) {
        final t = queue.removeAt(0);
        active.add(t.title);
        notifyListeners();
        try {
          await _download(host, port, pin, t);
          if (!t.hasArt || !store.artFile(t).existsSync()) {
            t.hasArt = await _fetchSmall(host, port, pin, '/api/art', {'path': t.path}, store.artFile(t));
          }
          store.tracks[t.id] = t;
          filesDone++;
          if (filesDone % 10 == 0) store.changed();
        } catch (e) {
          if (!_cancel) {
            filesFailed++;
            debugPrint('download failed ${t.path}: $e');
          }
        } finally {
          active.remove(t.title);
          notifyListeners();
        }
      }
    }

    await Future.wait([for (var i = 0; i < kParallelDownloads; i++) worker()]);

    // Unchanged tracks may still lack art (e.g. first sync was cancelled).
    // Also picks up retagged titles/artists for songs already on the phone.
    for (final t in remoteTracks.values) {
      if (_cancel) break;
      final local = store.tracks[t.id];
      if (local == null) continue; // never arrived (failed download)
      if (!identical(local, t)) {
        t.hasArt = local.hasArt;
        store.tracks[t.id] = t;
      }
      if (!t.hasArt) {
        t.hasArt = await _fetchSmall(host, port, pin, '/api/art', {'path': t.path}, store.artFile(t));
      }
    }

    // 4. Apply playlist structure. Only list songs that are actually on the phone.
    for (final p in newPlaylists) {
      p.trackIds.retainWhere((id) => store.tracks.containsKey(id) && store.localFile(store.tracks[id]!).existsSync());
    }

    // 5. Remove what was deleted on the PC (skipped when the sync was cancelled).
    if (store.mirrorDeletes && !_cancel) {
      final gone = store.tracks.keys.where((id) => !remoteTracks.containsKey(id)).toList();
      for (final id in gone) {
        await store.deleteTrack(id);
        removed++;
      }
      final keepFolders = newPlaylists.map((p) => p.folder).toSet();
      for (final p in store.playlists) {
        if (!keepFolders.contains(p.folder)) {
          final c = store.coverFile(p.folder);
          if (c.existsSync()) c.deleteSync();
        }
      }
      store.playlists = newPlaylists;
    } else {
      // Keep local-only playlists, update the rest.
      final byFolder = {for (final p in store.playlists) p.folder: p};
      for (final p in newPlaylists) {
        final old = byFolder[p.folder];
        if (old != null && _cancel) {
          // Keep songs from before, add the new ones that arrived.
          for (final id in old.trackIds) {
            if (!p.trackIds.contains(id) && store.tracks.containsKey(id)) p.trackIds.add(id);
          }
        }
        byFolder[p.folder] = p;
      }
      store.playlists = byFolder.values.toList();
    }
  }

  /// Streams one song to "<file>.part", resuming if a partial copy exists.
  Future<void> _download(String host, int port, String pin, Track t) async {
    final dest = store.localFile(t);
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > t.size) {
      await part.delete();
      have = 0;
    }

    final req = http.Request('GET', _uri(host, port, '/api/file', {'path': t.path}));
    req.headers.addAll(_headers(pin));
    if (have > 0) req.headers['Range'] = 'bytes=$have-';

    final res = await _client!.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode == 200) {
      have = 0; // server ignored the range: start over
    } else if (res.statusCode != 206) {
      await res.stream.drain();
      throw SyncException('HTTP ${res.statusCode}');
    }
    bytesDone += have;

    final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var got = have;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        if (_cancel) throw SyncException('cancelled');
        sink.add(chunk);
        got += chunk.length;
        bytesDone += chunk.length;
        notifyListeners();
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (got != t.size) throw SyncException('incomplete ($got of ${t.size} bytes)');
    if (await dest.exists()) await dest.delete();
    await part.rename(dest.path);
  }

  Future<bool> _fetchSmall(String host, int port, String pin, String path, Map<String, String> q, File out) async {
    try {
      final res = await _client!
          .get(_uri(host, port, path, q), headers: _headers(pin))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return false;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(res.bodyBytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
