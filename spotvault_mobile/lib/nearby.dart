import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'library_store.dart';
import 'player_service.dart';

/// Phones with SpotVault open on the same Wi-Fi (or one phone's hotspot) find
/// each other, send songs (Share) and play together (Jam).
///
/// Every phone runs a small HTTP server on [kNearbyPort]. Finding phones
/// checks every address on the Wi-Fi for that port (UDP broadcasts need an
/// Apple permission that sideloaded apps can't get).
const int kNearbyPort = 50510;

class NearbyPhone {
  final String host;
  final int port;
  final String name;
  final String id;
  final Map<String, dynamic>? jam; // {"mode", "title", "guests"} when hosting a Jam
  NearbyPhone(this.host, this.port, this.name, this.id, this.jam);
}

/// A song in a share or a Jam, as sent between phones.
class SongInfo {
  final String id;
  final String title;
  final String artist;
  final String album;
  final double duration;
  final int size;
  final String ext;
  final bool hasArt;
  SongInfo(this.id, this.title, this.artist, this.album, this.duration, this.size, this.ext, this.hasArt);

  factory SongInfo.of(Track t, LibraryStore store) => SongInfo(
        t.id,
        t.title,
        t.artist,
        t.album,
        t.duration,
        t.size,
        t.path.contains('.') ? t.path.split('.').last.toLowerCase() : 'm4a',
        t.hasArt && store.artFile(t).existsSync(),
      );

  factory SongInfo.fromJson(Map<String, dynamic> j) => SongInfo(
        '${j['id']}',
        '${j['title'] ?? ''}',
        '${j['artist'] ?? ''}',
        '${j['album'] ?? ''}',
        ((j['duration'] as num?) ?? 0).toDouble(),
        ((j['size'] as num?) ?? 0).toInt(),
        RegExp(r'^[a-z0-9]{2,4}$').hasMatch('${j['ext']}') ? '${j['ext']}' : 'm4a',
        j['hasArt'] == true,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'artist': artist, 'album': album, 'duration': duration, 'size': size, 'ext': ext, 'hasArt': hasArt};
}

/// Someone wants to send you songs.
class IncomingShare {
  final String fromName;
  final String host;
  final int port;
  final String token;
  final List<SongInfo> songs;
  final String? playlistName;
  final Completer<bool> answer = Completer<bool>();
  IncomingShare(this.fromName, this.host, this.port, this.token, this.songs, this.playlistName);
}

/// Someone wants to join your Jam.
class JoinRequest {
  final String name;
  final Completer<bool> answer = Completer<bool>();
  JoinRequest(this.name);
}

enum JamMode { speaker, sync }

/// One song in a Jam queue.
class JamItem {
  final String key;
  final SongInfo song;
  final String addedBy;
  // Where to fetch it from (the phone that added it).
  final String host;
  final int port;
  final String token;
  String? file; // local copy once fetched (host)
  bool failed = false;
  /// The phone that added it sends the file itself (works through BlueStacks
  /// and other networks where the host can't reach that phone).
  bool pushed = false;
  JamItem(this.key, this.song, this.addedBy, this.host, this.port, this.token);

  Map<String, dynamic> toJson() => {'key': key, ...song.toJson(), 'by': addedBy, 'ready': file != null, 'failed': failed};
}

class NearbyService extends ChangeNotifier {
  NearbyService(this.store, this.player, {this.port = kNearbyPort, String? name, String? id})
      : _name = name,
        _id = id;
  final LibraryStore store;
  final PlayerService player;
  /// This phone's server port (tests run a second "phone" on another port).
  final int port;
  final String? _name, _id;

  HttpServer? _server;
  String? serverError;
  final Random _rnd = Random.secure();

  /// Files this phone lets others fetch: token -> track ids.
  final Map<String, Set<String>> _grants = {};

  // ---- UI hooks (set by the app)
  Future<bool> Function(IncomingShare)? onIncomingShare;
  Future<bool> Function(JoinRequest)? onJoinRequest;

  // ---- discovery
  List<NearbyPhone> phones = [];
  bool scanning = false;

  // ---- receiving a share
  String? receiving; // status line while songs arrive
  int receiveDone = 0, receiveTotal = 0;

  /// Lets the Jam objects refresh the UI.
  void changed() => notifyListeners();

  String get myName => _name ?? store.deviceName;
  String get myId => _id ?? store.deviceId;

  String _token() => List.generate(20, (_) => _rnd.nextInt(16).toRadixString(16)).join();

  // ================================================================ server
  /// True while other phones can reach this one (checked every few seconds).
  bool reachable = false;
  Timer? _watchdog;
  int _misses = 0;
  AppLifecycleListener? _life;

  Future<void> start() async {
    // Phones put apps to sleep; iOS then silently closes the listening socket.
    // Check it regularly and whenever the app comes back, and reopen it.
    _watchdog ??= Timer.periodic(const Duration(seconds: 5), (_) => ensureRunning());
    try {
      _life ??= AppLifecycleListener(onResume: () => ensureRunning(force: true));
    } catch (_) {
      // No Flutter binding (plain unit tests): the timer still checks.
    }
    await _bind();
  }

  Future<void> _bind() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      _server!.listen(_handle, onError: (e) => debugPrint('nearby server: $e'), onDone: () => _server = null);
      serverError = null;
      reachable = true;
      _misses = 0;
    } catch (e) {
      serverError = 'Nearby sharing is unavailable: $e';
      reachable = false;
      debugPrint(serverError);
    }
    notifyListeners();
  }

  bool _checking = false;

  /// Connects to our own server; reopens it if it stopped answering.
  Future<void> ensureRunning({bool force = false}) async {
    if (_checking) return;
    _checking = true;
    try {
      var ok = false;
      if (_server != null) {
        try {
          final c = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
          c.destroy();
          ok = true;
        } catch (_) {}
      }
      if (ok) {
        _misses = 0;
        if (!reachable) {
          reachable = true;
          notifyListeners();
        }
        return;
      }
      _misses++;
      if (force || _misses >= 2 || _server == null) {
        debugPrint('nearby server not answering: reopening');
        try {
          await _server?.close(force: true);
        } catch (_) {}
        _server = null;
        reachable = false;
        await _bind();
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final q = req.uri.queryParameters;
      switch (path) {
        case '/nearby/hello':
          return await _json(res, {
            'app': 'SpotVault',
            'kind': 'phone',
            'name': myName,
            'id': myId,
            if (jamHost != null) 'jam': {'mode': jamHost!.mode.name, 'title': "$myName's Jam", 'guests': jamHost!.guests.length},
          });
        case '/nearby/file':
        case '/nearby/art':
          return await _serveTrack(req, q['t'] ?? '', q['id'] ?? '', art: path.endsWith('art'));
        case '/nearby/offer':
          return await _onOffer(req);
        case '/jam/join':
          return await _onJoin(req);
        case '/jam/state':
          return await _onJamState(req);
        case '/jam/add':
          return await _onJamAdd(req);
        case '/jam/control':
          return await _onJamControl(req);
        case '/jam/file':
          return await _onJamFile(req);
        case '/jam/leave':
          return await _onJamLeave(req);
        case '/jam/upload':
          return await _onJamUpload(req);
      }
      res.statusCode = 404;
      await res.close();
    } catch (e) {
      debugPrint('nearby request failed: $e');
      try {
        res.statusCode = 500;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, Object body, [int code = 200]) async {
    final bytes = utf8.encode(jsonEncode(body));
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }

  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final text = await utf8.decodeStream(req.take(1 << 20));
    return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _serveTrack(HttpRequest req, String token, String id, {bool art = false}) async {
    final res = req.response;
    final t = store.tracks[id];
    if (!(_grants[token]?.contains(id) ?? false) || t == null) {
      return _json(res, {'error': 'Not allowed'}, 403);
    }
    final f = art ? store.artFile(t) : store.localFile(t);
    return _serveFile(req, f);
  }

  /// Streams a file, honouring Range requests (the iPhone's player needs them).
  Future<void> _serveFile(HttpRequest req, File f) async {
    final res = req.response;
    if (!await f.exists()) return _json(res, {'error': 'Missing'}, 404);
    final size = await f.length();
    var start = 0, end = size - 1;
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (m != null && (m.group(1)!.isNotEmpty || m.group(2)!.isNotEmpty)) {
      if (m.group(1)!.isNotEmpty) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = min(int.parse(m.group(2)!), size - 1);
      } else {
        start = max(0, size - int.parse(m.group(2)!));
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
    }
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentType = ContentType('audio', 'mp4');
    res.contentLength = end - start + 1;
    await res.addStream(f.openRead(start, end + 1));
    await res.close();
  }

  // ================================================================ discovery
  /// Looks for SpotVault phones on this Wi-Fi (about 2 seconds).
  Future<List<NearbyPhone>> discover() async {
    if (scanning) return phones;
    scanning = true;
    phones = [];
    notifyListeners();
    try {
      final mine = <String>{};
      final subnets = <String>{};
      for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in nic.addresses) {
          if (a.isLoopback) continue;
          final p = a.address.split('.');
          if (p.length != 4) continue;
          final first = int.tryParse(p[0]) ?? 0, second = int.tryParse(p[1]) ?? 0;
          final private = first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168);
          if (!private) continue;
          mine.add(a.address);
          subnets.add('${p[0]}.${p[1]}.${p[2]}');
        }
      }
      final targets = [
        for (final s in subnets)
          for (var i = 1; i < 255; i++)
            if (!mine.contains('$s.$i')) '$s.$i'
      ];
      final client = http.Client();
      final seen = <String>{};
      Future<void> probe(String host) async {
        try {
          final r = await client
              .get(Uri(scheme: 'http', host: host, port: kNearbyPort, path: '/nearby/hello'))
              .timeout(const Duration(milliseconds: 900));
          if (r.statusCode != 200) return;
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          if (j['app'] != 'SpotVault' || j['kind'] != 'phone' || j['id'] == myId) return;
          if (!seen.add('${j['id']}')) return;
          phones = [
            ...phones,
            NearbyPhone(host, kNearbyPort, '${j['name'] ?? host}', '${j['id']}', (j['jam'] as Map?)?.cast<String, dynamic>()),
          ];
          notifyListeners();
        } catch (_) {}
      }

      // 64 at a time keeps it quick without flooding the router.
      for (var i = 0; i < targets.length; i += 64) {
        await Future.wait(targets.skip(i).take(64).map(probe));
      }
      client.close();
    } finally {
      scanning = false;
      notifyListeners();
    }
    return phones;
  }

  // ================================================================ share
  /// Offers [tracks] to [to]. Returns true if they accepted.
  Future<bool> share(NearbyPhone to, List<Track> tracks, {String? playlistName}) async {
    final token = _token();
    _grants[token] = tracks.map((t) => t.id).toSet();
    // Grants expire after an hour.
    Timer(const Duration(hours: 1), () => _grants.remove(token));
    final res = await http
        .post(Uri(scheme: 'http', host: to.host, port: to.port, path: '/nearby/offer'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'from': myName,
              'port': port,
              'token': token,
              'playlist': playlistName,
              'songs': [for (final t in tracks) SongInfo.of(t, store).toJson()],
            }))
        .timeout(const Duration(seconds: 100));
    return res.statusCode == 200 && jsonDecode(res.body)['accepted'] == true;
  }

  Future<void> _onOffer(HttpRequest req) async {
    final j = await _body(req);
    final songs = [for (final s in (j['songs'] as List? ?? const [])) SongInfo.fromJson(Map<String, dynamic>.from(s as Map))];
    final host = req.connectionInfo?.remoteAddress.address ?? '';
    if (songs.isEmpty || host.isEmpty || onIncomingShare == null || receiving != null) {
      return _json(req.response, {'accepted': false});
    }
    final offer = IncomingShare('${j['from'] ?? 'Someone'}', host, ((j['port'] as num?) ?? kNearbyPort).toInt(), '${j['token']}', songs,
        (j['playlist'] as String?)?.trim().isEmpty ?? true ? null : (j['playlist'] as String).trim());
    var ok = false;
    try {
      ok = await onIncomingShare!(offer).timeout(const Duration(seconds: 90));
    } catch (_) {}
    await _json(req.response, {'accepted': ok});
    if (ok) unawaited(_receive(offer));
  }

  /// The playlist folder a share goes into.
  String sharedFolder(IncomingShare offer) {
    final base = offer.playlistName != null ? '${offer.playlistName} (from ${offer.fromName})' : 'Shared with me';
    return base.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
  }

  /// Saves a song that arrived as a file (Bluetooth sharing). [audio] and
  /// [art] are temporary files and are moved or deleted. False if it failed.
  Future<bool> importShared(SongInfo s, String folder, File audio, File? art) async {
    try {
      final name = _safe(s.artist.isEmpty ? s.title : '${s.artist} - ${s.title}');
      final path = '$folder/$name.${s.ext}';
      final id = 'sh_${base64Url.encode(utf8.encode(path)).replaceAll('=', '')}';
      final dest = File('${store.musicDir.path}/$path');
      await dest.parent.create(recursive: true);
      if (await dest.exists()) {
        await audio.delete();
      } else {
        try {
          await audio.rename(dest.path);
        } on FileSystemException {
          // Different volume: copy instead.
          await audio.copy(dest.path);
          await audio.delete();
        }
      }
      final t = Track(
        id: id,
        path: path,
        title: s.title,
        artist: s.artist,
        album: s.album,
        size: await dest.length(),
        mtime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        duration: s.duration,
        phoneOnly: true,
      );
      if (art != null) {
        try {
          final a = store.artFile(t);
          await a.parent.create(recursive: true);
          await art.copy(a.path);
          t.hasArt = true;
        } catch (_) {}
        try {
          await art.delete();
        } catch (_) {}
      }
      store.addPhoneTrack(t, folder: folder, title: folder);
      return true;
    } catch (e) {
      debugPrint('share import failed for ${s.title}: $e');
      try {
        await audio.delete();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _receive(IncomingShare offer) async {
    final folderBase = offer.playlistName != null ? '${offer.playlistName} (from ${offer.fromName})' : 'Shared with me';
    final folder = folderBase.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    receiveTotal = offer.songs.length;
    receiveDone = 0;
    receiving = 'Getting ${offer.songs.length} song${offer.songs.length == 1 ? '' : 's'} from ${offer.fromName}…';
    notifyListeners();
    final client = http.Client();
    var failed = 0;
    try {
      for (final s in offer.songs) {
        final name = _safe(s.artist.isEmpty ? s.title : '${s.artist} - ${s.title}');
        final path = '$folder/$name.${s.ext}';
        final id = 'sh_${base64Url.encode(utf8.encode(path)).replaceAll('=', '')}';
        final dest = File('${store.musicDir.path}/$path');
        try {
          if (!await dest.exists()) {
            await _download(
                client,
                Uri(
                    scheme: 'http',
                    host: offer.host,
                    port: offer.port,
                    path: '/nearby/file',
                    queryParameters: {'t': offer.token, 'id': s.id}),
                dest);
          }
          final t = Track(
            id: id,
            path: path,
            title: s.title,
            artist: s.artist,
            album: s.album,
            size: await dest.length(),
            mtime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            duration: s.duration,
            phoneOnly: true,
          );
          if (s.hasArt) {
            try {
              await _download(
                  client,
                  Uri(
                      scheme: 'http',
                      host: offer.host,
                      port: offer.port,
                      path: '/nearby/art',
                      queryParameters: {'t': offer.token, 'id': s.id}),
                  store.artFile(t));
              t.hasArt = true;
            } catch (_) {}
          }
          store.addPhoneTrack(t, folder: folder, title: folder);
        } catch (e) {
          failed++;
          debugPrint('share receive failed for ${s.title}: $e');
        }
        receiveDone++;
        notifyListeners();
      }
    } finally {
      client.close();
      receiving = failed == 0 ? null : '$failed song${failed == 1 ? '' : 's'} could not be received.';
      notifyListeners();
      if (failed > 0) {
        Timer(const Duration(seconds: 8), () {
          receiving = null;
          notifyListeners();
        });
      }
    }
  }

  static String _safe(String s) {
    final c = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return c.length > 120 ? c.substring(0, 120) : (c.isEmpty ? 'Song' : c);
  }

  Future<void> _download(http.Client client, Uri uri, File dest) async {
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    final res = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 && res.statusCode != 206) throw HttpException('HTTP ${res.statusCode}');
    final sink = part.openWrite();
    try {
      await res.stream.timeout(const Duration(seconds: 30)).pipe(sink);
    } catch (e) {
      try {
        await part.delete();
      } catch (_) {}
      rethrow;
    }
    await part.rename(dest.path);
  }

  // ================================================================ Jam (host)
  JamHost? jamHost;
  JamGuest? jamGuest;

  bool get inJam => jamHost != null || jamGuest != null;

  Future<void> startJam(JamMode mode) async {
    await leaveJam();
    jamHost = JamHost(this, mode);
    notifyListeners();
  }

  Future<void> _onJoin(HttpRequest req) async {
    final j = await _body(req);
    final h = jamHost;
    if (h == null || onJoinRequest == null) return _json(req.response, {'error': 'No Jam here'}, 404);
    final r = JoinRequest('${j['name'] ?? 'Someone'}');
    var ok = false;
    try {
      ok = await onJoinRequest!(r).timeout(const Duration(seconds: 90));
    } catch (_) {}
    if (!ok) return _json(req.response, {'accepted': false});
    final token = _token();
    h.guests[token] = r.name;
    notifyListeners();
    await _json(req.response,
        {'accepted': true, 'token': token, 'mode': h.mode.name, 'host': myName, 'now': DateTime.now().millisecondsSinceEpoch});
  }

  Future<void> _onJamState(HttpRequest req) async {
    final h = jamHost;
    final token = req.uri.queryParameters['t'] ?? '';
    if (h == null || !h.guests.containsKey(token)) return _json(req.response, {'error': 'Not in this Jam'}, 403);
    await _json(req.response, h.state());
  }

  Future<void> _onJamAdd(HttpRequest req) async {
    final j = await _body(req);
    final h = jamHost;
    final token = '${j['t']}';
    if (h == null || !h.guests.containsKey(token)) return _json(req.response, {'error': 'Not in this Jam'}, 403);
    final host = req.connectionInfo?.remoteAddress.address ?? '';
    final songs = [for (final s in (j['songs'] as List? ?? const [])) SongInfo.fromJson(Map<String, dynamic>.from(s as Map))];
    final added = h.add(songs, h.guests[token]!, host, ((j['port'] as num?) ?? kNearbyPort).toInt(), '${j['serve']}',
        next: j['next'] == true, pushed: j['push'] == true);
    await _json(req.response, {'ok': true, 'keys': [for (final i in added) i.key]});
  }

  /// A guest sends a song (or its cover) it added: /jam/upload?t=&key=[&art=1][&fail=1].
  Future<void> _onJamUpload(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final h = jamHost;
    if (h == null || !h.guests.containsKey(q['t'])) return _json(req.response, {'error': 'Not in this Jam'}, 403);
    final item = h.items.where((i) => i.key == q['key'] && i.pushed).firstOrNull;
    if (item == null) return _json(req.response, {'error': 'Unknown song'}, 404);
    if (q['fail'] == '1') {
      item.failed = true;
      notifyListeners();
      return _json(req.response, {'ok': true});
    }
    await h._dir.create(recursive: true);
    final art = q['art'] == '1';
    final dest = File('${h._dir.path}/${item.key}.${art ? 'img' : item.song.ext}');
    final part = File('${dest.path}.part');
    final sink = part.openWrite();
    try {
      await sink.addStream(req.timeout(const Duration(seconds: 30)));
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
        await part.delete();
      } catch (_) {}
      if (!art) item.failed = true;
      notifyListeners();
      return _json(req.response, {'error': 'Upload failed'}, 400);
    }
    await part.rename(dest.path);
    if (art) {
      player.extraArt['jam:${item.key}'] = dest.path;
    } else {
      item.file = dest.path;
      await h._enqueue(item);
    }
    notifyListeners();
    await _json(req.response, {'ok': true});
  }

  /// Is a SpotVault phone at this address? (for "Join by address")
  Future<NearbyPhone?> hello(String host, int port) async {
    try {
      final r = await http
          .get(Uri(scheme: 'http', host: host, port: port, path: '/nearby/hello'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['app'] != 'SpotVault' || j['kind'] != 'phone') return null;
      return NearbyPhone(host, port, '${j['name'] ?? host}', '${j['id']}', (j['jam'] as Map?)?.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// This phone's Wi-Fi addresses, for others to type in.
  Future<List<String>> myAddresses() async {
    final out = <String>[];
    try {
      for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in nic.addresses) {
          final p = a.address.split('.');
          if (a.isLoopback || p.length != 4) continue;
          final f = int.tryParse(p[0]) ?? 0, s2 = int.tryParse(p[1]) ?? 0;
          if (f == 10 || (f == 172 && s2 >= 16 && s2 <= 31) || (f == 192 && s2 == 168)) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> _onJamControl(HttpRequest req) async {
    final j = await _body(req);
    final h = jamHost;
    if (h == null || !h.guests.containsKey('${j['t']}')) return _json(req.response, {'error': 'Not in this Jam'}, 403);
    await h.control('${j['action']}', index: (j['index'] as num?)?.toInt());
    await _json(req.response, {'ok': true});
  }

  Future<void> _onJamFile(HttpRequest req) async {
    final h = jamHost;
    final q = req.uri.queryParameters;
    if (h == null || !h.guests.containsKey(q['t'])) return _json(req.response, {'error': 'Not in this Jam'}, 403);
    final item = h.items.where((i) => i.key == q['key']).firstOrNull;
    if (item?.file == null) return _json(req.response, {'error': 'Not ready'}, 404);
    return _serveFile(req, File(item!.file!));
  }

  Future<void> _onJamLeave(HttpRequest req) async {
    final j = await _body(req);
    jamHost?.guests.remove('${j['t']}');
    notifyListeners();
    await _json(req.response, {'ok': true});
  }

  /// Ends the Jam you host, or leaves the one you joined.
  Future<void> leaveJam() async {
    final g = jamGuest;
    jamGuest = null;
    await g?.leave();
    final h = jamHost;
    jamHost = null;
    await h?.end();
    notifyListeners();
  }

  // ================================================================ Jam (guest)
  /// Asks [phone] to join its Jam. Returns an error message, or null when in.
  Future<String?> joinJam(NearbyPhone phone) async {
    await leaveJam();
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final res = await http
          .post(Uri(scheme: 'http', host: phone.host, port: phone.port, path: '/jam/join'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'name': myName}))
          .timeout(const Duration(seconds: 100));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['accepted'] != true) return '${phone.name} didn\'t let you in.';
      final t1 = DateTime.now().millisecondsSinceEpoch;
      jamGuest = JamGuest(this, phone, '${j['token']}', j['mode'] == 'sync' ? JamMode.sync : JamMode.speaker, '${j['host'] ?? phone.name}');
      await jamGuest!.syncClock(firstGuess: ((j['now'] as num).toInt() - (t0 + t1) ~/ 2));
      jamGuest!.startPolling();
      rememberPhone(phone);
      notifyListeners();
      return null;
    } catch (e) {
      return "Couldn't reach ${phone.name}. Are you both on the same Wi-Fi?";
    }
  }

  /// Saved phones: the ones you joined before, newest first (max 8).
  void rememberPhone(NearbyPhone phone) {
    store.savedPhones
      ..removeWhere((p) => p['id'] == phone.id || p['host'] == phone.host)
      ..insert(0, {'name': phone.name, 'id': phone.id, 'host': phone.host, 'port': phone.port});
    if (store.savedPhones.length > 8) store.savedPhones = store.savedPhones.sublist(0, 8);
    store.changed();
  }

  void forgetPhone(String id) {
    store.savedPhones.removeWhere((p) => p['id'] == id);
    store.changed();
  }

  /// Lets the Jam host fetch these songs from this phone.
  String grant(Iterable<Track> tracks) {
    final token = _token();
    _grants[token] = tracks.map((t) => t.id).toSet();
    Timer(const Duration(hours: 6), () => _grants.remove(token));
    return token;
  }
}

/// The Jam this phone hosts. The host plays everything; in sync mode guests
/// also play along on their own phones.
class JamHost {
  JamHost(this.nearby, this.mode) {
    _sub = nearby.player.player.currentIndexStream.listen((_) => nearby.changed());
  }
  final NearbyService nearby;
  final JamMode mode;
  final Map<String, String> guests = {}; // token -> name
  final List<JamItem> items = [];
  final http.Client _client = http.Client();
  bool _fetching = false;
  bool _started = false;
  StreamSubscription? _sub;
  int _seq = 0;

  PlayerService get _ps => nearby.player;
  Directory get _dir => Directory('${nearby.store.baseDir.path}/jam');

  /// Songs ready to play, in queue order (the player plays exactly these).
  List<JamItem> get ready => items.where((i) => i.file != null).toList();

  Map<String, dynamic> state() {
    final p = _ps.player;
    final cur = _ps.current;
    final playing = ready;
    final idx = cur == null ? -1 : playing.indexWhere((i) => 'jam:${i.key}' == cur.id);
    return {
      'mode': mode.name,
      'host': nearby.myName,
      'guests': guests.values.toList(),
      'queue': [for (final i in items) i.toJson()],
      'current': idx >= 0 ? playing[idx].key : null,
      'playing': p.playing,
      'position': p.position.inMilliseconds,
      'now': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Adds songs (from the host's own library: host = '').
  List<JamItem> add(List<SongInfo> songs, String by, String host, int port, String token, {bool next = false, bool pushed = false}) {
    final added = [
      for (final s in songs) JamItem('${DateTime.now().microsecondsSinceEpoch}-${_seq++}', s, by, host, port, token)..pushed = pushed
    ];
    if (next) {
      final cur = _ps.current;
      final at = cur == null ? items.length : items.indexWhere((i) => 'jam:${i.key}' == cur.id) + 1;
      items.insertAll(at.clamp(0, items.length), added);
    } else {
      items.addAll(added);
    }
    nearby.changed();
    _fetchLoop();
    return added;
  }

  void addOwn(List<Track> tracks, {bool next = false}) {
    final token = nearby.grant(tracks);
    add([for (final t in tracks) SongInfo.of(t, nearby.store)], nearby.myName, '', nearby.port, token, next: next);
  }

  /// Fetches songs in queue order and hands each to the player when it lands.
  Future<void> _fetchLoop() async {
    if (_fetching) return;
    _fetching = true;
    try {
      while (true) {
        final next = items.where((i) => i.file == null && !i.failed && !i.pushed).firstOrNull;
        if (next == null || nearby.jamHost != this) break;
        try {
          if (next.host.isEmpty) {
            // The host's own song: play it from the library.
            final t = nearby.store.tracks[next.song.id];
            if (t == null) throw StateError('gone');
            next.file = nearby.store.localFile(t).path;
          } else {
            await _dir.create(recursive: true);
            final dest = File('${_dir.path}/${next.key}.${next.song.ext}');
            await nearby._download(
                _client,
                Uri(
                    scheme: 'http',
                    host: next.host,
                    port: next.port,
                    path: '/nearby/file',
                    queryParameters: {'t': next.token, 'id': next.song.id}),
                dest);
            next.file = dest.path;
            if (next.song.hasArt) {
              final art = File('${_dir.path}/${next.key}.img');
              try {
                await nearby._download(
                    _client,
                    Uri(
                        scheme: 'http',
                        host: next.host,
                        port: next.port,
                        path: '/nearby/art',
                        queryParameters: {'t': next.token, 'id': next.song.id}),
                    art);
                _ps.extraArt['jam:${next.key}'] = art.path;
              } catch (_) {}
            }
          }
          await _enqueue(next);
        } catch (e) {
          next.failed = true;
          debugPrint('jam fetch failed: $e');
        }
        nearby.changed();
      }
    } finally {
      _fetching = false;
    }
  }

  Track _trackFor(JamItem i) => Track(
        id: 'jam:${i.key}',
        path: 'jam/${i.key}.${i.song.ext}',
        title: i.song.title,
        artist: i.song.artist,
        album: i.addedBy,
        size: i.song.size,
        mtime: 0,
        duration: i.song.duration,
      );

  Future<void> _enqueue(JamItem i) async {
    final t = _trackFor(i);
    _ps.extraTracks[t.id] = t;
    _ps.extraFiles[t.id] = i.file!;
    if (!_started) {
      _started = true;
      await _ps.playTracks([t]);
      return;
    }
    // Keep the player's order equal to the queue's order.
    final readyKeys = ready.map((r) => r.key).toList();
    final pos = readyKeys.indexOf(i.key);
    final len = _ps.player.sequence.length;
    if (pos >= len) {
      await _ps.player.addAudioSource(_ps.sourceFor(t));
    } else {
      await _ps.player.insertAudioSource(pos, _ps.sourceFor(t));
    }
    if (!_ps.player.playing && _ps.player.processingState == ProcessingState.completed) {
      await _ps.player.seek(Duration.zero, index: pos);
      _ps.player.play();
    }
  }

  Future<void> control(String action, {int? index}) async {
    final p = _ps.player;
    switch (action) {
      case 'play':
        p.play();
      case 'pause':
        await p.pause();
      case 'next':
        await p.seekToNext();
      case 'previous':
        await _ps.previous();
      case 'seek':
        if (index != null) await p.seek(Duration(milliseconds: index));
      case 'jump':
        if (index != null) {
          final key = index >= 0 && index < items.length ? items[index].key : null;
          final pos = ready.indexWhere((r) => r.key == key);
          if (pos >= 0) {
            await p.seek(Duration.zero, index: pos);
            p.play();
          }
        }
    }
    nearby.changed();
  }

  Future<void> end() async {
    await _sub?.cancel();
    _client.close();
    if (_started) await _ps.player.stop();
    _ps.extraTracks.removeWhere((k, _) => k.startsWith('jam:'));
    _ps.extraFiles.removeWhere((k, _) => k.startsWith('jam:'));
    _ps.extraArt.removeWhere((k, _) => k.startsWith('jam:'));
    try {
      if (await _dir.exists()) await _dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// The Jam this phone joined.
class JamGuest {
  JamGuest(this.nearby, this.hostPhone, this.token, this.mode, this.hostName);
  final NearbyService nearby;
  final NearbyPhone hostPhone;
  final String token;
  final JamMode mode;
  final String hostName;
  Map<String, dynamic> state = {};
  String? error;
  int _offset = 0; // host clock - my clock, in ms
  int get clockOffset => _offset;
  Timer? _poll;
  final http.Client _client = http.Client();
  String? _playingKey;
  final Map<String, String> _files = {};
  final Set<String> _fetching = {};

  PlayerService get _ps => nearby.player;
  Directory get _dir => Directory('${nearby.store.baseDir.path}/jam_guest');

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: hostPhone.host, port: hostPhone.port, path: path, queryParameters: {'t': token, ...?q});

  List<Map<String, dynamic>> get queue => [for (final q in (state['queue'] as List? ?? const [])) Map<String, dynamic>.from(q as Map)];

  /// Estimates the host's clock offset from a few round trips.
  Future<void> syncClock({required int firstGuess}) async {
    _offset = firstGuess;
    var best = 1 << 30;
    for (var i = 0; i < 12; i++) {
      try {
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final r = await _client.get(_u('/jam/state')).timeout(const Duration(seconds: 3));
        final t1 = DateTime.now().millisecondsSinceEpoch;
        final now = (jsonDecode(r.body)['now'] as num).toInt();
        if (t1 - t0 < best) {
          best = t1 - t0;
          _offset = now - (t0 + t1) ~/ 2;
        }
      } catch (_) {}
    }
  }

  Timer? _resync;

  void startPolling() {
    _poll?.cancel();
    // Sync mode checks twice a second so phones stay together.
    _poll = Timer.periodic(Duration(milliseconds: mode == JamMode.sync ? 500 : 1000), (_) => _tick());
    // Clocks drift: measure the host's clock again every half minute.
    _resync?.cancel();
    if (mode == JamMode.sync) _resync = Timer.periodic(const Duration(seconds: 30), (_) => syncClock(firstGuess: _offset));
    _tick();
  }

  /// How long a seek takes to be heard on this phone (learned as we go).
  int _seekLag = 120;
  DateTime? _seekedAt;
  int? _seekTarget;

  Future<void> _tick() async {
    try {
      final r = await _client.get(_u('/jam/state')).timeout(const Duration(seconds: 4));
      if (r.statusCode == 403) {
        error = 'The Jam ended.';
        _poll?.cancel();
        nearby.jamGuest = null;
        await _stopLocal();
        nearby.changed();
        return;
      }
      state = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      error = null;
      if (mode == JamMode.sync) await _follow();
    } catch (_) {
      error = 'Lost contact with $hostName…';
    }
    nearby.changed();
  }

  /// Sync mode: play the host's song at the host's position.
  Future<void> _follow() async {
    final key = state['current'] as String?;
    if (key == null) return;
    final file = _files[key] ?? await _fetch(key);
    if (file == null) return;
    final item = queue.firstWhere((q) => q['key'] == key, orElse: () => {});
    final p = _ps.player;
    final hostPlaying = state['playing'] == true;
    final at = Duration(
        milliseconds: (state['position'] as num).toInt() +
            (hostPlaying ? DateTime.now().millisecondsSinceEpoch + _offset - (state['now'] as num).toInt() : 0));
    if (_playingKey != key) {
      _playingKey = key;
      final t = Track(
        id: 'jamg:$key',
        path: 'jam_guest/$key',
        title: '${item['title'] ?? ''}',
        artist: '${item['artist'] ?? ''}',
        album: '',
        size: 0,
        mtime: 0,
        duration: ((item['duration'] as num?) ?? 0).toDouble(),
      );
      _ps.extraTracks[t.id] = t;
      _ps.extraFiles[t.id] = file;
      await _ps.playTracks([t]);
      await p.seek(at + const Duration(milliseconds: 250));
      if (!hostPlaying) await p.pause();
      return;
    }
    if (hostPlaying && !p.playing) p.play();
    if (!hostPlaying && p.playing) await p.pause();
    if (!hostPlaying) return;
    // Bluetooth speakers play late: start that much earlier.
    final target = at.inMilliseconds + nearby.store.jamDelayMs;
    final drift = p.position.inMilliseconds - target; // + = we are ahead
    // Learn how long seeks take on this phone from the last one.
    if (_seekedAt != null && DateTime.now().difference(_seekedAt!) < const Duration(seconds: 2) && _seekTarget != null) {
      _seekLag = (_seekLag - drift ~/ 2).clamp(0, 900);
      _seekedAt = null;
    }
    final a = drift.abs();
    if (a > 600) {
      // Far off: jump, aiming a little ahead to cover the seek itself.
      _seekTarget = target;
      _seekedAt = DateTime.now();
      if (p.speed != 1) await p.setSpeed(1);
      await p.seek(Duration(milliseconds: target + _seekLag));
    } else if (a > 30) {
      // Close: speed up or slow down slightly until we line up (no audible jump).
      final sp = drift > 0 ? (a > 200 ? 0.94 : 0.98) : (a > 200 ? 1.06 : 1.02);
      if (p.speed != sp) await p.setSpeed(sp);
    } else if (p.speed != 1) {
      await p.setSpeed(1);
    }
  }

  Future<String?> _fetch(String key) async {
    if (!_fetching.add(key)) return null;
    try {
      await _dir.create(recursive: true);
      final dest = File('${_dir.path}/$key.m4a');
      await nearby._download(_client, _u('/jam/file', {'key': key}), dest);
      _files[key] = dest.path;
      return dest.path;
    } catch (_) {
      return null;
    } finally {
      _fetching.remove(key);
    }
  }

  /// Adds songs to the host's queue, then sends each file to the host.
  Future<void> add(List<Track> tracks, {bool next = false}) async {
    final serve = nearby.grant(tracks);
    final r = await _client
        .post(Uri(scheme: 'http', host: hostPhone.host, port: hostPhone.port, path: '/jam/add'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              't': token,
              'serve': serve,
              'port': nearby.port,
              'next': next,
              'push': true,
              'songs': [for (final t in tracks) SongInfo.of(t, nearby.store).toJson()],
            }))
        .timeout(const Duration(seconds: 10));
    final keys = List<String>.from((jsonDecode(r.body) as Map<String, dynamic>)['keys'] as List? ?? const []);
    await _tick();
    _uploads = _uploads.then((_) => _send(tracks, keys));
  }

  Future<void> _uploads = Future.value();

  /// Sends songs one by one, in queue order (each with its cover first).
  Future<void> _send(List<Track> tracks, List<String> keys) async {
    for (var i = 0; i < tracks.length && i < keys.length; i++) {
      if (nearby.jamGuest != this) return;
      final t = tracks[i];
      try {
        final art = nearby.store.artFile(t);
        if (t.hasArt && await art.exists()) await _upload(keys[i], art, art: true);
        await _upload(keys[i], nearby.store.localFile(t));
      } catch (e) {
        debugPrint('jam upload failed: $e');
        try {
          await _client.post(_u('/jam/upload', {'key': keys[i], 'fail': '1'})).timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
      await _tick();
    }
  }

  Future<void> _upload(String key, File f, {bool art = false}) async {
    final req = http.StreamedRequest('POST', _u('/jam/upload', {'key': key, if (art) 'art': '1'}))
      ..contentLength = await f.length();
    final sent = _client.send(req);
    await req.sink.addStream(f.openRead());
    await req.sink.close();
    final res = await sent.timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw HttpException('upload ${res.statusCode}');
  }

  Future<void> control(String action, {int? index}) async {
    await _client
        .post(Uri(scheme: 'http', host: hostPhone.host, port: hostPhone.port, path: '/jam/control'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'t': token, 'action': action, 'index': index}))
        .timeout(const Duration(seconds: 6));
    await _tick();
  }

  Future<void> _stopLocal() async {
    if (mode == JamMode.sync && _playingKey != null) await _ps.player.stop();
    _ps.extraTracks.removeWhere((k, _) => k.startsWith('jamg:'));
    _ps.extraFiles.removeWhere((k, _) => k.startsWith('jamg:'));
    try {
      if (await _dir.exists()) await _dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> leave() async {
    _poll?.cancel();
    _resync?.cancel();
    if (_ps.player.speed != 1) await _ps.player.setSpeed(1);
    try {
      await _client
          .post(Uri(scheme: 'http', host: hostPhone.host, port: hostPhone.port, path: '/jam/leave'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'t': token}))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    _client.close();
    await _stopLocal();
  }
}
