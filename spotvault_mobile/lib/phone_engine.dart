import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:serious_python/serious_python.dart';

import 'update_service.dart' show kAppVersion;

/// The downloader that runs on the phone itself.
///
/// The app ships a small Python program (spotvault_mobile/python/main.py)
/// with yt-dlp, ytmusicapi and the PC's clean-music filter. It serves the
/// same HTTP API as the PC on 127.0.0.1, protected by a random token, so
/// [PcLink] can talk to either one.
///
/// Python can only start once per app process. If the phone puts the app to
/// sleep and its socket is closed, Python notices and listens again on the
/// same port, so callers wait a little ([_waitAlive]) instead of failing.
class PhoneEngine {
  PhoneEngine._();
  static final PhoneEngine instance = PhoneEngine._();

  /// Tests set this so the engine accepts /api/_break.
  static bool testMode = false;

  int port = 0;
  String token = '';
  Future<void>? _starting;
  String? logPath;
  String? _dataDir;

  /// Why Python itself failed to start, if it did.
  String? runError;

  bool get ready => port != 0 && _starting == null;

  /// Starts Python once per app process and waits until it answers.
  Future<void> ensureStarted({required String musicDir, required String artDir, required String dataDir}) {
    _dataDir = dataDir;
    logPath = '$dataDir/engine.log';
    if (port != 0 && _starting == null) return _check();
    return _starting ??= _start(musicDir, artDir, dataDir).whenComplete(() => _starting = null);
  }

  Future<void> _check() async {
    if (await _waitAlive(const Duration(seconds: 15))) return;
    await note('downloader not answering on port $port');
    throw EngineException('The downloader stopped. Close SpotVault completely and open it again.');
  }

  File get _stateFile => File('$_dataDir/engine.json');

  Future<void> _start(String musicDir, String artDir, String dataDir) async {
    // Android can recreate the app's screen while the process (and Python)
    // keeps running: reuse that Python instead of starting a second one.
    try {
      final f = _stateFile;
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        port = (j['port'] as num).toInt();
        token = j['token'] as String;
        if (await _alive() && await _tokenWorks()) {
          await note('reusing running downloader on port $port');
          return;
        }
      }
    } catch (_) {}
    port = 0;

    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = sock.port;
    await sock.close();
    final rnd = Random.secure();
    token = List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
    try {
      final old = File(logPath!);
      if (await old.exists() && await old.length() > 512 * 1024) await old.delete();
    } catch (_) {}
    port = p;
    runError = null;
    String appDir = '';
    try {
      appDir = await SeriousPython.prepareApp();
    } catch (e) {
      await note('prepareApp failed: $e');
    }
    await note('starting downloader on port $p (app $kAppVersion)');
    SeriousPython.run(
      appFileName: 'main.py',
      environmentVariables: {
        'SV_PORT': '$p',
        'SV_TOKEN': token,
        'SV_MUSIC': musicDir,
        'SV_ART': artDir,
        'SV_LOG': logPath!,
        'SV_VERSION': kAppVersion,
        'SV_APP': appDir,
        if (testMode) 'SV_TEST': '1',
        'PYTHONUNBUFFERED': '1',
      },
    ).catchError((Object e) {
      runError = '$e';
      note('Python could not start: $e');
      return null;
    });
    // First launch on Android unpacks Python, which takes a while.
    if (await _waitAlive(const Duration(seconds: 90))) {
      try {
        await _stateFile.writeAsString(jsonEncode({'port': port, 'token': token}));
      } catch (_) {}
      return;
    }
    await note("downloader didn't start (runError=$runError)");
    throw EngineException("The downloader didn't start. Close SpotVault completely and open it again.");
  }

  Future<bool> _waitAlive(Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (true) {
      if (await _alive()) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<bool> _alive() async {
    if (port == 0) return false;
    try {
      final res = await http
          .get(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/api/status'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200 && jsonDecode(res.body)['engine'] == 'phone';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tokenWorks() async {
    try {
      final res = await http
          .get(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/api/job', queryParameters: {'id': 'x'}),
              headers: {'X-SpotVault-Pin': token})
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 404;
    } catch (_) {
      return false;
    }
  }

  /// Adds a line from the app's side to the downloader log.
  Future<void> note(String line) async {
    debugPrint('engine: $line');
    final path = logPath;
    if (path == null) return;
    try {
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      await File(path).writeAsString('${two(t.hour)}:${two(t.minute)}:${two(t.second)} app: $line\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<String> readLog() async {
    try {
      final f = File(logPath ?? '');
      return await f.exists() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  /// Tests: forget the running engine as if the app's screen was recreated.
  @visibleForTesting
  void debugForget() {
    port = 0;
    token = '';
  }
}

class EngineException implements Exception {
  final String message;
  EngineException(this.message);
  @override
  String toString() => message;
}
