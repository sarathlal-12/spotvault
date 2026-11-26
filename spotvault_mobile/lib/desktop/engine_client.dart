import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_state.dart';

/// One line of the live sync feed.
class FeedItem {
  final int seq;
  final String kind, title, detail, path, playlist;
  FeedItem(Map<String, dynamic> j)
      : seq = (j['seq'] as num).toInt(),
        kind = '${j['kind']}',
        title = '${j['title']}',
        detail = '${j['detail'] ?? ''}',
        path = '${j['path'] ?? ''}',
        playlist = '${j['playlist'] ?? ''}';
}

/// The Windows app's link to the SpotVault engine (the PC downloader, which
/// runs hidden next to the app and also serves phones).
class EngineClient extends ChangeNotifier {
  static const int port = 50505;
  final String token = List.generate(24, (_) => Random.secure().nextInt(16).toRadixString(16)).join();

  Process? _proc;
  Timer? _timer;
  bool ready = false;
  String error = '';
  Map<String, dynamic> state = {};
  final List<FeedItem> feed = [];
  int _seq = 0;
  bool _wasRunning = false;
  int _libraryStamp = -1;

  /// Called when a sync finishes or playlists change, to re-read the library.
  Future<void> Function()? onLibraryChanged;

  Map<String, dynamic> get sync => (state['sync'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get syncing => sync['running'] == true;
  double get progress => ((sync['progress'] as num?) ?? 0).toDouble();
  List<Map<String, dynamic>> get playlists => [for (final p in (state['playlists'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
  Map<String, dynamic> get phone => (state['phone'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic>? get lastReport => (state['last_report'] as Map?)?.cast<String, dynamic>();
  String get masterFolder => '${state['master_folder'] ?? ''}';

  Uri _u(String path, [Map<String, String>? q]) => Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: q);
  Map<String, String> get _h => {'X-SpotVault-Pin': token, 'Content-Type': 'application/json'};

  /// Finds the engine next to the app (installed) or runs src/engine.py (development).
  Future<void> start() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      File('${exeDir.path}\\engine\\SpotVaultEngine.exe'),
      File('${exeDir.path}\\SpotVaultEngine.exe'),
    ];
    final env = {...Platform.environment, 'SV_LOCAL_TOKEN': token, 'SV_PARENT_PID': '$pid'};
    try {
      final exe = candidates.where((f) => f.existsSync()).firstOrNull;
      if (exe != null) {
        await _clearLeftoverEngine();
        _proc = await Process.start(exe.path, const [], workingDirectory: exeDir.path, environment: env);
      } else {
        // Development: python src/engine.py, run from the repository root.
        final root = Platform.environment['SV_REPO'] ?? Directory.current.parent.path;
        _proc = await Process.start('python', ['$root\\src\\engine.py'], workingDirectory: Platform.environment['SV_ENGINE_CWD'] ?? root, environment: env);
      }
      _proc!.stdout.transform(utf8.decoder).listen((l) => debugPrint('[engine] $l'));
      _proc!.stderr.transform(utf8.decoder).listen((l) => debugPrint('[engine] $l'));
      unawaited(_proc!.exitCode.then((code) {
        if (!ready) {
          error = code == 2
              ? 'Another app is using port $port, so the downloader could not start. Close that app and reopen SpotVault.'
              : 'The downloader stopped (code $code).';
          notifyListeners();
        }
      }));
    } catch (e) {
      error = "Couldn't start the downloader: $e";
      notifyListeners();
      return;
    }
    for (var i = 0; i < 120 && !ready && error.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      await refresh();
    }
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => refresh());
  }

  /// An engine from an earlier run that didn't quit (it holds port 50505 and
  /// would block this launch): end it first.
  Future<void> _clearLeftoverEngine() async {
    Future<bool> portFree() async {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await s.close();
        return true;
      } catch (_) {
        return false;
      }
    }

    if (await portFree()) return;
    try {
      await Process.run('taskkill', ['/F', '/T', '/IM', 'SpotVaultEngine.exe']);
    } catch (_) {}
    for (var i = 0; i < 20 && !await portFree(); i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> refresh() async {
    try {
      final r = await http.get(_u('/api/engine/state', {'since': '$_seq'}), headers: _h).timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return;
      state = jsonDecode(r.body) as Map<String, dynamic>;
      final first = !ready;
      ready = true;
      error = '';
      for (final e in (state['feed'] as List? ?? const [])) {
        feed.add(FeedItem((e as Map).cast<String, dynamic>()));
      }
      if (feed.length > 300) feed.removeRange(0, feed.length - 300);
      _seq = (state['seq'] as num?)?.toInt() ?? _seq;
      // Re-read the library after a sync, or when playlists or folders change.
      final stamp = Object.hashAll([masterFolder, for (final p in playlists) '${p['folder']}:${p['songs']}']);
      final ended = _wasRunning && !syncing;
      _wasRunning = syncing;
      if (first || ended || (!syncing && stamp != _libraryStamp)) {
        _libraryStamp = stamp;
        unawaited(onLibraryChanged?.call());
      }
      notifyListeners();
    } catch (_) {
      // The engine is starting or busy; try again on the next tick.
    }
  }

  Future<String?> _post(String path, Map<String, dynamic> body) async {
    try {
      final r = await http.post(_u('/api/engine$path'), headers: _h, body: jsonEncode(body)).timeout(const Duration(seconds: 60));
      final j = jsonDecode(r.body);
      unawaited(refresh());
      return r.statusCode == 200 ? null : '${j['error'] ?? 'Something went wrong'}';
    } catch (e) {
      return "The downloader didn't answer ($e).";
    }
  }

  /// The songs of a playlist link, for Play online. Throws on failure.
  Future<List<Map<String, dynamic>>> tracks(String url) async {
    final r = await http.get(_u('/api/tracks', {'url': url}), headers: _h).timeout(const Duration(seconds: 60));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw Exception('${j['error'] ?? "Couldn't read that playlist"}');
    return [for (final t in (j['tracks'] as List? ?? const [])) (t as Map).cast<String, dynamic>()];
  }

  /// Trending charts: {"charts": [{id, title}], "songs": [{title, artist, art, url, secs}]}.
  Future<Map<String, dynamic>> trending({String country = 'IN', String chart = 'apple'}) async {
    final r = await http.get(_u('/api/trending', {'country': country, 'chart': chart}), headers: _h).timeout(const Duration(seconds: 40));
    final j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    if (r.statusCode != 200) throw Exception('${j['error'] ?? "Couldn't load the chart"}');
    return j;
  }

  /// A stream of one online song: its link, or (Spotify) the best match for its name.
  Uri streamFor(Map<String, dynamic> t) {
    final url = '${t['url'] ?? ''}';
    return _u('/api/preview', {
      if (url.isNotEmpty) 'url': url else 'q': '${t['title']} ${t['artist'] ?? ''}'.trim(),
      'pin': token,
    });
  }

  /// Song list import: {playlist: ["Title - Artist", ...]}; each song is found and downloaded.
  Future<String?> importLists(Map<String, List<String>> lists, {List<String> also = const []}) => _post('/import', {'lists': lists, 'also': also});

  /// Songs stored more than once: {exact, exact_bytes, review: [{files: [{path, folder, name, size, seconds, bitrate}], keep, title, artist}], done}.
  Future<Map<String, dynamic>> dupes() async {
    final r = await http.post(_u('/api/engine/dupes'), headers: _h, body: '{}').timeout(const Duration(minutes: 3));
    final j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    if (r.statusCode != 200) throw Exception('${j['error'] ?? "Couldn't check for duplicates"}');
    return j;
  }

  Future<String?> linkCopies() => _post('/dupes/link', {});

  /// Builds the one-click Claude Desktop extension: (path, error).
  Future<(String?, String?)> mcpb() async {
    try {
      final r = await http.post(_u('/api/engine/mcpb'), headers: _h, body: '{}').timeout(const Duration(seconds: 30));
      final j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      return r.statusCode == 200 ? ('${j['path']}', null) : (null, '${j['error'] ?? 'Something went wrong'}');
    } catch (e) {
      return (null, "The downloader didn't answer ($e).");
    }
  }
  Future<String?> mergeCopies(String keep, List<String> others) => _post('/dupes/merge', {'keep': keep, 'others': others});

  Future<String?> syncAll() => _post('/sync', {});
  Future<String?> syncFolders(List<String> folders) => _post('/sync', {'folders': folders});
  Future<String?> stop() => _post('/stop', {});
  Future<String?> addPlaylist(String url) => _post('/add', {'url': url});
  Future<String?> removePlaylist(String folder, {bool deleteFiles = false}) => _post('/remove', {'folder': folder, 'delete_files': deleteFiles});
  Future<String?> renamePlaylist(String folder, String title) => _post('/rename', {'folder': folder, 'title': title});
  Future<String?> downloadSongs(String folder, List<String> urls, {List<String> also = const []}) =>
      _post('/download', {'folder': folder, 'urls': urls, 'also': also});
  Future<String?> setMasterFolder(String path) => _post('/settings', {'master_folder': path});
  Future<String?> setSpotifyKey(String id, String secret) => _post('/settings', {'spotify_id': id, 'spotify_secret': secret});
  Future<String?> skipUpdate(String version) => _post('/settings', {'skip_update': version});
  Future<String?> newPin() => _post('/new_pin', {});
  Future<String?> installUpdate() => _post('/install_update', {});
  Future<String?> open([String path = '']) => _post('/open', {'path': path});

  Future<Map<String, dynamic>> report() async {
    final r = await http.get(_u('/api/engine/report'), headers: _h).timeout(const Duration(seconds: 10));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> checkUpdate() async {
    final r = await http.get(_u('/api/engine/update'), headers: _h).timeout(const Duration(seconds: 15));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Reads the PC library through the engine (the same way phones sync), but
  /// the songs stay where they are: the app plays the PC's own files.
  Future<void> loadLibrary() async {
    if (!ready || masterFolder.isEmpty) return;
    store.musicDir = Directory(masterFolder);
    await syncService.sync('127.0.0.1:$port', token);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _proc?.kill();
    super.dispose();
  }
}

final EngineClient engine = EngineClient();
