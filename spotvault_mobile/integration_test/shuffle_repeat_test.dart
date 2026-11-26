// Windows shuffle / repeat check with the real mpv player, set up like the app
// (main.dart: media_kit + the EQ hook).
//
//   flutter test integration_test/shuffle_repeat_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/desktop/eq.dart';
import 'package:spotvault_mobile/library_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shuffle and repeat work on Windows', (tester) async {
    JustAudioMediaKit.ensureInitialized(windows: true);
    Eq.instance.attach();
    final tmp = Directory.systemTemp.createTempSync('sv_shuffle');
    store.baseDir = tmp;
    store.musicDir = Directory('${tmp.path}/Music')..createSync();
    store.artDir = Directory('${tmp.path}/art')..createSync();
    store.coverDir = Directory('${tmp.path}/covers')..createSync();

    final tracks = <Track>[];
    for (var i = 0; i < 8; i++) {
      final t = Track(
        id: 'sh$i',
        path: 'Test mix/tone$i.m4a',
        title: 'Song $i',
        artist: 'Test',
        album: '',
        size: 1,
        mtime: 0,
        duration: 45,
        addedAt: i,
        hasArt: false,
      );
      store.tracks[t.id] = t;
      playerService.extraFiles[t.id] = File('integration_test/assets/tone${i % 3 + 1}.m4a').absolute.path;
      tracks.add(t);
    }

    final ps = playerService;
    final p = ps.player;
    await ps.init();
    await p.setVolume(0.02);
    Future<void> wait(int ms) => tester.runAsync(() => Future.delayed(Duration(milliseconds: ms)));

    // ---- shuffle
    await ps.playTracks(tracks, shuffle: false);
    await wait(2500);
    final before = (ps.current?.id, p.position);
    final states = <ProcessingState>{};
    final sub = p.processingStateStream.listen(states.add);
    await ps.toggleShuffle();
    await wait(1000);
    await sub.cancel();
    // ignore: avoid_print
    print('NO GAP song ${before.$1} -> ${ps.current?.id}, pos ${before.$2} -> ${p.position}, states=$states');
    expect(ps.current?.id, before.$1, reason: 'shuffle changed the song');
    expect(p.position >= before.$2, isTrue, reason: 'shuffle restarted the song');
    expect(states.contains(ProcessingState.loading), isFalse, reason: 'shuffle reloaded the song');
    // Shuffle off again and back on: still the same song, still playing.
    await ps.toggleShuffle();
    await wait(600);
    final unshuffled = [for (final t in ps.queue) t.id];
    // ignore: avoid_print
    print('UNSHUFFLED $unshuffled');
    expect(unshuffled.first, before.$1);
    await ps.toggleShuffle();
    await wait(600);
    final shown = [for (final t in ps.queue) t.id];
    final played = [ps.current?.id];
    for (var i = 0; i < 4; i++) {
      await ps.next();
      await wait(1200);
      played.add(ps.current?.id);
    }
    // ignore: avoid_print
    print('SHUFFLE on=${ps.shuffleOn} queue=$shown played=$played');
    expect(ps.shuffleOn, isTrue);
    expect(shown, isNot([for (final t in tracks) t.id]), reason: 'queue was not shuffled');
    expect(played, shown.take(5).toList(), reason: 'songs did not play in the shuffled order');

    // ---- repeat one
    // ignore: avoid_print
    print('LOOP start=${p.loopMode}');
    await ps.cycleLoop(); // off -> all
    // ignore: avoid_print
    print('LOOP after 1 click=${ps.loopMode}');
    await ps.cycleLoop(); // all -> one, clicked right away
    // ignore: avoid_print
    print('LOOP after 2 clicks=${p.loopMode}');
    await wait(800);
    // ignore: avoid_print
    print('LOOP mode=${p.loopMode}');
    expect(p.loopMode, LoopMode.one);
    final id = ps.current?.id;
    final len = p.duration ?? const Duration(seconds: 45);
    await p.seek(len - const Duration(seconds: 2));
    await wait(5000);
    // ignore: avoid_print
    print('REPEAT ONE before=$id after=${ps.current?.id} pos=${p.position}');
    expect(ps.current?.id, id, reason: 'repeat one moved to another song');

    // ---- repeat all: the last song wraps to the first
    await ps.cycleLoop(); // one -> off
    await ps.cycleLoop(); // off -> all
    await p.seek(Duration.zero, index: p.sequence.length - 1);
    await wait(1000);
    final last = ps.current?.id;
    await p.seek((p.duration ?? len) - const Duration(seconds: 2));
    await wait(5000);
    // ignore: avoid_print
    print('REPEAT ALL last=$last after=${ps.current?.id} first=${ps.queue.first.id} playing=${p.playing}');
    expect(ps.current?.id, ps.queue.first.id, reason: 'repeat all did not wrap to the first song');

    // ---- an online list (Trending): shuffle and repeat work there too
    await ps.cycleLoop(); // all -> one
    await wait(500);
    final online = [
      for (var i = 0; i < 6; i++)
        (
          Uri.file(File('integration_test/assets/tone${i % 3 + 1}.m4a').absolute.path),
          Track(id: 'online:t$i', path: '', title: 'Chart $i', artist: 'Web', album: '', size: 0, mtime: 0, duration: 45, addedAt: 0, hasArt: false),
        ),
    ];
    await ps.playOnline(online, key: 'chart');
    await wait(1500);
    // ignore: avoid_print
    print('ONLINE loop kept=${p.loopMode} shuffle=${ps.shuffleOn}');
    expect(p.loopMode, LoopMode.one, reason: 'online list turned repeat off');
    await ps.cycleLoop(); // one -> off
    await ps.toggleShuffle();
    await wait(1000);
    final oq = [for (final t in ps.queue) t.id];
    final op = [ps.current?.id];
    for (var i = 0; i < 3; i++) {
      await ps.next();
      await wait(1200);
      op.add(ps.current?.id);
    }
    // ignore: avoid_print
    print('ONLINE SHUFFLE on=${ps.shuffleOn} queue=$oq played=$op');
    expect(ps.shuffleOn, isTrue);
    expect(oq, isNot([for (final s in online) s.$2.id]));
    expect(op, oq.take(4).toList());
    // Back to your own songs: your shuffle (on) comes back.
    await ps.playTracks(tracks);
    await wait(1000);
    // ignore: avoid_print
    print('BACK shuffle=${ps.shuffleOn} loop=${p.loopMode}');
    expect(ps.shuffleOn, isTrue);
    await p.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
