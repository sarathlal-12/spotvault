import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'library_store.dart';
import 'nearby.dart';
import 'pc_link.dart';
import 'player_service.dart';

/// The relay that carries Internet Jam messages (jam-relay/ in this repo,
/// deployed to Cloudflare). Only small messages go through it, never audio.
const String kJamRelay = 'https://spotvault-jam.spotvault.workers.dev';

/// The relay in use (tests point it at a local one).
String jamRelay = kJamRelay;

enum NetRole { none, host, guest }

/// A guest in your Jam, as the host sees it.
class NetGuest {
  final String id;
  final String name;
  NetGuest(this.id, this.name);
}

/// A song as it travels in a Jam (name only; each phone finds the audio).
class NetSong {
  final String title, artist, url, thumb;
  final double duration;
  NetSong(this.title, this.artist, {this.duration = 0, this.url = '', this.thumb = ''});

  String get key => '${title.trim().toLowerCase()}|${artist.trim().toLowerCase()}';

  factory NetSong.fromJson(Map<String, dynamic> j) => NetSong(
        '${j['title'] ?? ''}',
        '${j['artist'] ?? ''}',
        duration: ((j['duration'] as num?) ?? 0).toDouble(),
        url: '${j['url'] ?? ''}',
        thumb: '${j['thumb'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'title': title, 'artist': artist, 'duration': duration, if (url.isNotEmpty) 'url': url, if (thumb.isNotEmpty) 'thumb': thumb};
}

/// Jam over the internet. The host's phone plays from its own library and
/// sends what's playing (song, position, play/pause, up next) through the
/// relay. Each guest's phone plays the same song at the same moment: from
/// its own library when it has the song, otherwise streamed from the web by
/// the phone's own downloader. Guests join by code or link; the host lets
/// each one in.
class NetJamService extends ChangeNotifier {
  final LibraryStore store;
  final PlayerService player;
  final PcLink web;
  final NearbyService nearby;
  NetJamService(this.store, this.player, this.web, this.nearby);

  NetRole role = NetRole.none;
  bool get active => role != NetRole.none;
  String code = '';
  String hostName = '';

  /// Short status line ("Waiting for Saad to let you in…"), or null.
  String? status;
  List<NetGuest> guests = [];

  /// What the host is playing (guests), for the Jam screen.
  NetSong? nowPlaying;
  List<NetSong> upNext = [];

  WebSocket? _ws;
  String _key = '';
  final String _myId = List.generate(16, (_) => math.Random.secure().nextInt(36).toRadixString(36)).join();
  Timer? _ping, _push, _follow;
  bool _closing = false;
  int _retries = 0;

  static Uri _http(String path) => Uri.parse('$jamRelay$path');
  static String _wsUrl(String path, Map<String, String> q) =>
      Uri.parse(jamRelay.replaceFirst('http', 'ws') + path).replace(queryParameters: q).toString();

  String get _name => store.deviceName.isEmpty ? 'Phone' : store.deviceName;

  // ---------------------------------------------------------------- clock
  /// Relay time minus this phone's time, from the best (fastest) ping.
  int _offset = 0;
  int _bestRtt = 1 << 30;
  int get serverNow => DateTime.now().millisecondsSinceEpoch + _offset;

  void _pong(Map<String, dynamic> m) {
    final c = (m['c'] as num?)?.toInt();
    final s = (m['s'] as num?)?.toInt();
    if (c == null || s == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rtt = now - c;
    // Prefer quick round trips; let old samples age out slowly.
    if (rtt <= _bestRtt * 1.3 || rtt < 150) {
      _bestRtt = math.min(_bestRtt, rtt);
      _offset = s - (c + rtt ~/ 2);
    }
  }

  void _sendPing() => _send({'t': 'ping', 'c': DateTime.now().millisecondsSinceEpoch});

  // ---------------------------------------------------------------- socket
  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  Future<bool> _connect(Map<String, String> q) async {
    try {
      final ws = await WebSocket.connect(_wsUrl('/rooms/$code/ws', q)).timeout(const Duration(seconds: 12));
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      _retries = 0;
      ws.listen(
        (raw) {
          if (raw is! String) return;
          try {
            _onMessage(Map<String, dynamic>.from(jsonDecode(raw) as Map));
          } catch (e) {
            debugPrint('netjam: bad message $e');
          }
        },
        onDone: () => _lost(q),
        onError: (_) => _lost(q),
        cancelOnError: true,
      );
      _bestRtt = 1 << 30;
      for (var i = 0; i < 4; i++) {
        Timer(Duration(milliseconds: 150 * i), _sendPing);
      }
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 10), (_) => _sendPing());
      return true;
    } catch (e) {
      debugPrint('netjam: connect failed $e');
      return false;
    }
  }

  /// Connection dropped: try again (phones switch networks, tunnels…).
  void _lost(Map<String, String> q) {
    _ws = null;
    if (_closing || !active) return;
    status = 'Reconnecting…';
    notifyListeners();
    final wait = Duration(seconds: math.min(30, 2 << math.min(_retries++, 4)));
    Timer(wait, () async {
      if (_closing || !active || _ws != null) return;
      if (await _connect(q)) {
        status = null;
        notifyListeners();
      } else {
        _lost(q);
      }
    });
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'pong':
        _pong(m);
      case 'request':
        if (role == NetRole.host) _askJoin('${m['id']}', '${m['name'] ?? 'Someone'}');
      case 'guests':
        guests = [for (final g in (m['list'] as List? ?? const [])) NetGuest('${(g as Map)['id']}', '${g['name']}')];
        notifyListeners();
      case 'req':
        if (role == NetRole.host) _onGuestRequest(m);
      case 'waiting':
        status = 'Waiting for ${hostName.isEmpty ? 'the host' : hostName} to let you in…';
        notifyListeners();
      case 'hostAway':
        status = '${hostName.isEmpty ? 'The host' : hostName} is offline. Waiting for them…';
        notifyListeners();
      case 'hostBack':
      case 'welcome':
        status = null;
        notifyListeners();
      case 'state':
        if (role == NetRole.guest) _onState(m);
      case 'denied':
        _endLocal('${hostName.isEmpty ? 'The host' : hostName} said no.');
      case 'kicked':
        _endLocal('You were removed from the Jam.');
      case 'ended':
        _endLocal(role == NetRole.guest ? 'The Jam ended.' : null);
    }
  }

  // ---------------------------------------------------------------- host
  /// Starts a Jam others can join from anywhere. Returns an error or null.
  Future<String?> host() async {
    await leave();
    try {
      final res = await http.post(_http('/rooms')).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 'The Jam service answered ${res.statusCode}. Try again in a minute.';
      final j = jsonDecode(res.body) as Map;
      code = '${j['code']}';
      _key = '${j['key']}';
    } catch (_) {
      return 'No internet connection, or the Jam service is down.';
    }
    role = NetRole.host;
    hostName = _name;
    _closing = false;
    if (!await _connect({'role': 'host', 'key': _key, 'name': _name})) {
      role = NetRole.none;
      return "Couldn't connect to the Jam service.";
    }
    player.addListener(_pushSoon);
    _push = Timer.periodic(const Duration(seconds: 2), (_) => _pushState());
    _pushState();
    notifyListeners();
    return null;
  }

  Timer? _pushDebounce;
  void _pushSoon() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(milliseconds: 150), _pushState);
  }

  void _pushState() {
    if (role != NetRole.host || _ws == null) return;
    final t = player.current;
    final p = player.player;
    final order = player.playOrder;
    final seq = p.sequence;
    final cur = p.currentIndex ?? 0;
    final at = order.indexOf(cur);
    final next = <Map<String, dynamic>>[];
    if (at >= 0) {
      for (final i in order.skip(at + 1).take(5)) {
        final id = (seq[i].tag as MediaItem).id;
        final tr = player.trackById(id);
        if (tr != null) next.add(NetSong(tr.title, tr.artist, duration: tr.duration).toJson());
      }
    }
    final song = t == null ? null : NetSong(t.title, t.artist, duration: t.duration).toJson();
    _send({
      't': 'state',
      'song': song,
      'pos': p.position.inMilliseconds,
      'playing': p.playing && t != null,
      'at': serverNow,
      'next': next,
      'host': _name,
    });
  }

  Future<void> _askJoin(String id, String name) async {
    var ok = false;
    final ask = nearby.onJoinRequest;
    if (ask != null) {
      try {
        ok = await ask(JoinRequest(name)).timeout(const Duration(seconds: 120));
      } catch (_) {}
    }
    _send({'t': 'approve', 'id': id, 'ok': ok});
    if (ok) _pushState();
  }

  Future<void> _onGuestRequest(Map<String, dynamic> m) async {
    switch (m['action']) {
      case 'play':
        player.player.play();
      case 'pause':
        player.player.pause();
      case 'next':
        await player.next();
      case 'prev':
        await player.previous();
      case 'add':
        final s = NetSong.fromJson(Map<String, dynamic>.from((m['song'] as Map?) ?? const {}));
        if (s.title.isEmpty) return;
        // Already in the library: queue it. Otherwise download it, then it plays next.
        final have = _inLibrary(s);
        if (have != null) {
          await player.addToQueue(have);
        } else if (s.url.isNotEmpty) {
          final list = store.playlists.where((p) => p.name == 'Jam requests').firstOrNull ?? store.createPlaylist('Jam requests');
          try {
            await web.download(OnlineSong(title: s.title, artist: s.artist, duration: '', url: s.url, thumb: s.thumb), list, playWhenReady: true);
          } catch (e) {
            debugPrint('netjam: request download failed $e');
          }
        }
        _pushState();
    }
  }

  /// Removes a guest from your Jam.
  void kick(String id) => _send({'t': 'kick', 'id': id});

  // ---------------------------------------------------------------- guest
  /// Asks to join the Jam with [joinCode]. Returns an error or null.
  Future<String?> join(String joinCode) async {
    await leave();
    code = joinCode.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{6}$').hasMatch(code)) return 'A Jam code has 6 letters and numbers.';
    try {
      final res = await http.get(_http('/rooms/$code')).timeout(const Duration(seconds: 12));
      final j = jsonDecode(res.body) as Map;
      if (res.statusCode != 200 || j['open'] != true) return 'No Jam with that code. It may have ended.';
      hostName = '${j['host'] ?? ''}';
    } catch (_) {
      return 'No internet connection, or the Jam service is down.';
    }
    role = NetRole.guest;
    _closing = false;
    status = 'Asking to join…';
    notifyListeners();
    if (!await _connect({'role': 'guest', 'id': _myId, 'name': _name})) {
      role = NetRole.none;
      status = null;
      notifyListeners();
      return "Couldn't connect to the Jam service.";
    }
    player.holdPreview = true;
    _follow = Timer.periodic(const Duration(seconds: 1), (_) => _correct());
    return null;
  }

  /// Ask the host's phone to do something.
  void request(String action, {NetSong? song}) => _send({'t': 'req', 'action': action, if (song != null) 'song': song.toJson()});

  Map<String, dynamic>? _state;
  int _stateAt = 0; // our clock when the state arrived
  String _loadedKey = '';
  bool _loading = false;
  final Map<String, Future<Uri?>> _found = {};

  void _onState(Map<String, dynamic> m) {
    _state = m;
    _stateAt = DateTime.now().millisecondsSinceEpoch;
    if ('${m['host'] ?? ''}'.isNotEmpty) hostName = '${m['host']}';
    final song = m['song'] is Map ? NetSong.fromJson(Map<String, dynamic>.from(m['song'] as Map)) : null;
    nowPlaying = song;
    upNext = [for (final s in (m['next'] as List? ?? const [])) NetSong.fromJson(Map<String, dynamic>.from(s as Map))];
    notifyListeners();
    // Look up the next song early so it starts on time.
    if (upNext.isNotEmpty) _source(upNext.first);
    _correct();
  }

  /// Where the host is in the song right now (ms).
  int _targetMs() {
    final m = _state;
    if (m == null) return 0;
    final pos = (m['pos'] as num?)?.toInt() ?? 0;
    if (m['playing'] != true) return pos;
    final at = (m['at'] as num?)?.toInt();
    final elapsed = at != null ? serverNow - at : DateTime.now().millisecondsSinceEpoch - _stateAt;
    return pos + math.max(0, elapsed);
  }

  Future<void> _correct() async {
    final m = _state;
    if (role != NetRole.guest || m == null || _loading) return;
    final song = nowPlaying;
    if (song == null) {
      if (player.player.playing) await player.player.pause();
      return;
    }
    if (song.key != _loadedKey) {
      _loading = true;
      try {
        final uri = await _source(song);
        if (uri == null) {
          status = "Couldn't find \"${song.title}\". Skipping until the next song.";
          _loadedKey = song.key;
          notifyListeners();
          return;
        }
        await player.playPreview(uri, key: 'jam:${song.key}', title: song.title, artist: song.artist, artUrl: song.thumb);
        _loadedKey = song.key;
        if (status != null && status!.startsWith("Couldn't find")) status = null;
        await player.player.seek(Duration(milliseconds: _targetMs()));
      } catch (e) {
        debugPrint('netjam: load failed $e');
      } finally {
        _loading = false;
      }
    }
    if (!player.previewing || player.previewKey != 'jam:${song.key}') return;
    final p = player.player;
    final shouldPlay = m['playing'] == true;
    if (shouldPlay && !p.playing) p.play();
    if (!shouldPlay && p.playing) await p.pause();
    final drift = p.position.inMilliseconds - _targetMs();
    // Small differences don't matter across the internet; big ones do.
    if (drift.abs() > 900 && p.processingState == ProcessingState.ready) {
      await p.seek(Duration(milliseconds: _targetMs() + (shouldPlay ? 250 : 0)));
    }
  }

  Track? _inLibrary(NetSong s) {
    final title = s.title.trim().toLowerCase();
    final artist = s.artist.trim().toLowerCase();
    for (final t in store.tracks.values) {
      if (t.title.trim().toLowerCase() != title) continue;
      final a = t.artist.trim().toLowerCase();
      if (artist.isEmpty || a.isEmpty || a.contains(artist) || artist.contains(a)) {
        if (store.localFile(t).existsSync()) return t;
      }
    }
    return null;
  }

  /// Where to play [s] from: this phone's own copy, or a stream from the web.
  Future<Uri?> _source(NetSong s) => _found[s.key] ??= () async {
        final have = _inLibrary(s);
        if (have != null) return Uri.file(store.localFile(have).path);
        try {
          final results = s.url.isNotEmpty
              ? [OnlineSong(title: s.title, artist: s.artist, duration: '', url: s.url, thumb: s.thumb)]
              : await web.search('${s.artist} ${s.title}'.trim());
          if (results.isEmpty) return null;
          final uri = await web.previewUri(results.first);
          // Warm the stream so playback starts quickly.
          unawaited(http.get(uri, headers: {'Range': 'bytes=0-1'}).timeout(const Duration(seconds: 40)).then((_) {}, onError: (_) {}));
          return uri;
        } catch (e) {
          debugPrint('netjam: find failed $e');
          _found.remove(s.key);
          return null;
        }
      }();

  // ---------------------------------------------------------------- leave
  void _endLocal(String? message) {
    final wasGuest = role == NetRole.guest;
    _closing = true;
    _ping?.cancel();
    _push?.cancel();
    _follow?.cancel();
    player.removeListener(_pushSoon);
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
    role = NetRole.none;
    guests = [];
    nowPlaying = null;
    upNext = [];
    _state = null;
    _loadedKey = '';
    _found.clear();
    status = message;
    if (wasGuest) {
      player.holdPreview = false;
      unawaited(player.stopPreview());
    }
    notifyListeners();
  }

  /// Ends your Jam (host) or leaves it (guest).
  Future<void> leave() async {
    if (!active) return;
    if (role == NetRole.host) _send({'t': 'end'});
    _endLocal(null);
  }
}
