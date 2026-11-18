// Windows media controls check: plays three test tones through SpotVault's own
// player with the real Windows runner (smtc.cpp), and writes what the player is
// doing to a status file every half second, so a script outside the app can press
// the Win+A / media-key buttons and see the effect.
//
//   flutter test integration_test/smtc_test.dart -d windows
//   (status file: %TEMP%\spotvault_smtc_status.json; runs ~100 s)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/windows_media.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('media controls follow the player', (tester) async {
    JustAudioMediaKit.ensureInitialized(windows: true);
    // A throwaway library, so the real one is never touched.
    final tmp = Directory.systemTemp.createTempSync('sv_smtc');
    store.baseDir = tmp;
    store.musicDir = Directory('${tmp.path}/Music')..createSync();
    store.artDir = Directory('${tmp.path}/art')..createSync();
    store.coverDir = Directory('${tmp.path}/covers')..createSync();

    final names = [('Midnight Drive', 'Night Cassette'), ('Neon Rain', 'Mira Vale'), ('Golden Hour', 'Juno Bay')];
    final tracks = <Track>[];
    for (var i = 0; i < 3; i++) {
      final t = Track(
        id: 'smtc$i',
        path: 'Test mix/tone${i + 1}.m4a',
        title: names[i].$1,
        artist: names[i].$2,
        album: '',
        size: 1,
        mtime: 0,
        duration: 45,
        addedAt: i,
        hasArt: true,
      );
      store.tracks[t.id] = t;
      playerService.extraFiles[t.id] = File('integration_test/assets/tone${i + 1}.m4a').absolute.path;
      File('test_shots/promo_art/c$i.png').copySync(store.artFile(t).path);
      tracks.add(t);
    }

    await playerService.init();
    WindowsMedia(playerService, store).start();
    await playerService.playTracks(tracks, shuffle: false);

    final status = File('${Platform.environment['TEMP']}\\spotvault_smtc_status.json');
    final p = playerService.player;
    for (var i = 0; i < 200; i++) {
      await p.setVolume(0.05); // quiet tones
      status.writeAsStringSync(jsonEncode({
        'title': playerService.current?.title,
        'index': p.currentIndex,
        'playing': p.playing,
        'position': p.position.inMilliseconds,
        'tick': i,
      }));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
    }
    await p.stop();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
