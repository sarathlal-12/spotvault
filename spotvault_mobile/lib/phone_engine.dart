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
class PhoneEngine {
  PhoneEngine._();
  static final PhoneEngine instance = PhoneEngine._();

  int port = 0;
  String token = '';
  Future<void>? _starting;
  bool _ran = false;
  String? logPath;

  bool get ready => port != 0 && _starting == null;

  /// Starts Python once per app run and waits until it answers.
  Future<void> ensureStarted({required String musicDir, required String artDir, required String dataDir}) {
    if (port != 0 && _starting == null) return _check();
    return _starting ??= _start(musicDir, artDir, dataDir).whenComplete(() => _starting = null);
  }

  Future<void> _check() async {
    if (await _alive()) return;
    throw EngineException('The downloader stopped. Close SpotVault and open it again.');
  }

  Future<void> _start(String musicDir, String artDir, String dataDir) async {
    if (_ran) {
      // Python can only be started once per app run.
      if (await _alive()) return;
      throw EngineException('The downloader stopped. Close SpotVault and open it again.');
    }
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = sock.port;
    await sock.close();
    final rnd = Random.secure();
    token = List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
    logPath = '$dataDir/engine.log';
    try {
      final old = File(logPath!);
      if (await old.exists() && await old.length() > 512 * 1024) await old.delete();
    } catch (_) {}
    _ran = true;
    port = p;
    SeriousPython.run(
      appFileName: 'main.py',
      environmentVariables: {
        'SV_PORT': '$p',
        'SV_TOKEN': token,
        'SV_MUSIC': musicDir,
        'SV_ART': artDir,
        'SV_LOG': logPath!,
        'SV_VERSION': kAppVersion,
        'PYTHONUNBUFFERED': '1',
      },
    );
    // First launch on Android unpacks Python, which takes a while.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      if (await _alive()) return;
      await Future.delayed(const Duration(milliseconds: 400));
    }
    debugPrint('Phone engine did not start. Log:\n${await readLog()}');
    throw EngineException("The downloader didn't start. Close SpotVault and open it again.");
  }

  Future<bool> _alive() async {
    try {
      final res = await http
          .get(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/api/status'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200 && jsonDecode(res.body)['engine'] == 'phone';
    } catch (_) {
      return false;
    }
  }

  Future<String> readLog() async {
    try {
      final f = File(logPath ?? '');
      return await f.exists() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }
}

class EngineException implements Exception {
  final String message;
  EngineException(this.message);
  @override
  String toString() => message;
}
