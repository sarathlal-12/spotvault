// Live check of song recognition (needs the internet and a clip):
//   SV_CLIP=<16 kHz mono s16le .raw> flutter test test/shazam_live_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/recognize/shazam_client.dart';

void main() {
  final clip = Platform.environment['SV_CLIP'];
  test('Shazam recognises a song clip', () async {
    final bytes = File(clip!).readAsBytesSync();
    final pcm = Int16List.view(bytes.buffer, 0, bytes.length ~/ 2);
    final song = await ShazamClient.recognize(pcm);
    // ignore: avoid_print
    print('RESULT: ${song?.title} / ${song?.artist}');
    expect(song, isNotNull);
  }, skip: clip == null ? 'set SV_CLIP' : false, timeout: const Timeout(Duration(seconds: 60)));
}
