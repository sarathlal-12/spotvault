import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'shazam_signature.dart';

/// A song Shazam recognised.
class RecognizedSong {
  final String title, artist, cover, shazamUrl;
  const RecognizedSong({required this.title, required this.artist, this.cover = '', this.shazamUrl = ''});
}

class RecognizeException implements Exception {
  final String message;
  RecognizeException(this.message);
  @override
  String toString() => message;
}

/// Asks Shazam's free recognition service (the one the Shazam apps use; no
/// account or key) what song a clip of audio is.
class ShazamClient {
  static final _rnd = math.Random();

  static String _uuid() {
    String h(int n) => List.generate(n, (_) => _rnd.nextInt(16).toRadixString(16)).join();
    return '${h(8)}-${h(4)}-4${h(3)}-${'89ab'[_rnd.nextInt(4)]}${h(3)}-${h(12)}'.toUpperCase();
  }

  /// Builds the fingerprint off the UI thread.
  static Future<(String, int)> signature(Int16List pcm16k) => compute(_sign, pcm16k);

  static (String, int) _sign(Int16List pcm) {
    final s = ShazamSignature()..addSamples(pcm);
    return (s.encode(), s.sampleMs);
  }

  /// [pcm16k]: about 8-12 s of 16 kHz mono audio. Null when nothing matched.
  static Future<RecognizedSong?> recognize(Int16List pcm16k) async {
    if (pcm16k.length < ShazamSignature.sampleRate * 3) throw RecognizeException('That was too short. Try again.');
    final (uri, ms) = await signature(pcm16k);
    final now = DateTime.now().millisecondsSinceEpoch;
    final url = Uri.https('amp.shazam.com', '/discovery/v5/en/US/iphone/-/tag/${_uuid()}/${_uuid()}', {
      'sync': 'true',
      'webv3': 'true',
      'sampling': 'true',
      'connected': '',
      'shazamapiversion': 'v3',
      'sharehub': 'true',
      'hubv5minorversion': 'v5.1',
      'hidelb': 'true',
      'video': 'v3',
    });
    final http.Response res;
    try {
      res = await http
          .post(url,
              headers: {
                'Content-Type': 'application/json',
                'Accept': '*/*',
                'Accept-Language': 'en-US',
                'X-Shazam-Platform': 'IPHONE',
                'X-Shazam-AppVersion': '14.1.0',
                'User-Agent': 'Shazam/3685 CFNetwork/1197 Darwin/20.0.0',
              },
              body: jsonEncode({
                'timezone': 'Asia/Kolkata',
                'signature': {'uri': uri, 'samplems': ms},
                'timestamp': now,
                'context': {},
                'geolocation': {},
              }))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw RecognizeException('No internet connection. Song recognition needs the internet.');
    }
    if (res.statusCode == 429) throw RecognizeException('Too many tries. Wait a minute and try again.');
    if (res.statusCode != 200) throw RecognizeException('Song recognition is unavailable right now (${res.statusCode}).');
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final t = j['track'] as Map<String, dynamic>?;
    if (t == null) return null;
    final images = (t['images'] as Map?)?.cast<String, dynamic>() ?? const {};
    return RecognizedSong(
      title: '${t['title'] ?? ''}',
      artist: '${t['subtitle'] ?? ''}',
      cover: '${images['coverarthq'] ?? images['coverart'] ?? ''}',
      shazamUrl: '${t['url'] ?? ''}',
    );
  }
}
