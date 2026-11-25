// Song recognition check on Windows: plays a song through SpotVault's player,
// records the PC's own sound (audio_capture.cpp, WASAPI loopback) and asks
// Shazam what it is.
//
//   flutter test integration_test/recognize_test.dart -d windows --dart-define=SV_SONG=<path to a song>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/recognize/recognize_sheet.dart';
import 'package:spotvault_mobile/recognize/shazam_client.dart';

const song = String.fromEnvironment('SV_SONG');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recognises what the PC plays', (tester) async {
    JustAudioMediaKit.ensureInitialized(windows: true);
    final tmp = Directory.systemTemp.createTempSync('sv_rec');
    store.baseDir = tmp;
    store.musicDir = Directory('${tmp.path}/Music')..createSync();
    store.artDir = Directory('${tmp.path}/art')..createSync();
    store.coverDir = Directory('${tmp.path}/covers')..createSync();
    final t = Track(id: 'rec0', path: 'x/song.m4a', title: 'Test', artist: '', album: '', size: 1, mtime: 0, duration: 200, addedAt: 0, hasArt: false);
    store.tracks[t.id] = t;
    playerService.extraFiles[t.id] = song;
    await playerService.init();
    await playerService.playTracks([t], shuffle: false);
    await playerService.player.seek(const Duration(seconds: 50));
    await playerService.player.setVolume(0.5);
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));

    final pcm = await tester.runAsync(() => AudioListen.record(device: true, ms: 10000));
    // ignore: avoid_print
    print('CAPTURED ${pcm!.length} samples');
    final found = await tester.runAsync(() => ShazamClient.recognize(pcm));
    // ignore: avoid_print
    print('RECOGNISED: ${found?.title} / ${found?.artist}');
    await playerService.player.stop();
    expect(found, isNotNull);
  }, skip: song.isEmpty);
}
