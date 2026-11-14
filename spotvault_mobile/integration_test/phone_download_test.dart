// Runs on a real iPhone simulator / Android emulator (see
// .github/workflows/device-test.yml). Checks that the phone can find, preview,
// download and play songs with no PC: the on-phone Python downloader.
//
// GitHub's machines are in data centres, and YouTube often answers them with
// "Sign in to confirm you're not a bot". Phones on home Wi-Fi or mobile data
// are not treated that way. So the YouTube part reports a block instead of
// failing, and SoundCloud (which doesn't block) proves the full path:
// search -> preview -> download -> tag -> cover -> play on the phone's player.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:serious_python/serious_python.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/pc_link.dart';
import 'package:spotvault_mobile/phone_engine.dart';

// ignore: avoid_print
void say(Object o) => print(o);

Future<void> dumpLog(String why) async {
  say('--- $why. runError=${PhoneEngine.instance.runError}');
  try {
    final app = await SeriousPython.prepareApp();
    say('app dir: ${Directory(app).listSync().map((e) => e.path.split('/').last).toList()}');
  } catch (e) {
    say('prepareApp failed: $e');
  }
  say('Engine log:\n${await PhoneEngine.instance.readLog()}');
}

bool _blocked(String text) {
  final t = text.toLowerCase();
  return t.contains('not a bot') || t.contains('sign in');
}

/// Previews, downloads and plays [song]. Returns false if YouTube blocked it.
Future<bool> saveAndPlay(OnlineSong song, PlaylistInfo playlist) async {
  final uri = await pcLink.previewUri(song);
  final res = await http.get(uri, headers: {'Range': 'bytes=0-1023'}).timeout(const Duration(seconds: 60));
  say('preview ${song.url}: ${res.statusCode} ${res.headers['content-type']} ${res.bodyBytes.length} bytes');
  if (res.statusCode != 206) {
    final log = await PhoneEngine.instance.readLog();
    if (_blocked(log)) return false;
    await dumpLog('preview failed');
    fail('preview answered ${res.statusCode}');
  }

  final sw = Stopwatch()..start();
  await pcLink.download(song, playlist);
  final job = pcLink.jobs.last;
  say('download: ${job.state} "${job.message}" in ${sw.elapsed.inSeconds}s');
  if (job.state != DlState.saved) {
    if (_blocked(job.message) || _blocked(await PhoneEngine.instance.readLog())) return false;
    await dumpLog('download failed');
  }
  expect(job.state, DlState.saved);

  final ids = store.playlists.firstWhere((p) => p.folder == playlist.folder).trackIds;
  final t = store.tracks[ids.last]!;
  expect(t.phoneOnly, isTrue);
  final f = store.localFile(t);
  say('saved: ${t.path} ${f.lengthSync()} bytes, ${t.duration.round()}s, art=${t.hasArt}, "${t.title}" by "${t.artist}"');
  expect(f.existsSync(), isTrue);
  expect(f.lengthSync(), greaterThan(300 * 1024));
  expect(t.duration, greaterThan(60));
  expect(t.hasArt, isTrue);

  // The phone's own player must play the file (no FFmpeg was used).
  final player = AudioPlayer();
  final d = await player.setFilePath(f.path);
  say('player: duration $d');
  expect(d, isNotNull);
  expect(d!.inSeconds, greaterThan(60));
  await player.seek(Duration(seconds: d.inSeconds ~/ 2));
  await player.dispose();

  // Saving the same song again is recognised.
  await pcLink.download(song, playlist);
  expect(pcLink.jobs.last.message, startsWith('Already in'));
  return true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone finds, previews, downloads and plays songs by itself', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final base = Directory('${docs.path}/sv_it')..createSync(recursive: true);
    store.baseDir = base;
    store.musicDir = Directory('${base.path}/Music')..createSync(recursive: true);
    store.artDir = Directory('${base.path}/art')..createSync(recursive: true);
    store.coverDir = Directory('${base.path}/covers')..createSync(recursive: true);
    store.useBridge = false;

    try {
      // 1. Normal search (clean order: YouTube Music, SoundCloud, YouTube).
      final sw = Stopwatch()..start();
      final results = await pcLink.search('Believer Imagine Dragons');
      say('engine start + search: ${sw.elapsed.inSeconds}s, ${results.length} results');
      for (final r in results.take(3)) {
        say('  ${r.title} / ${r.artist} / ${r.duration} / ${r.url}');
      }
      expect(results, isNotEmpty);

      // 2. YouTube Music download (may be blocked on GitHub's data-centre IP).
      final ytm = await pcLink.search('Believer Imagine Dragons', source: 'ytmusic');
      say('ytmusic search: ${ytm.length} results');
      expect(ytm, isNotEmpty, reason: 'YouTube Music search must work on the phone');
      expect(ytm.first.url, contains('music.youtube.com'));
      final ytOk = await saveAndPlay(ytm.first, PlaylistInfo(folder: 'YT Test', title: 'YT Test', trackIds: []));
      say(ytOk ? 'YOUTUBE MUSIC: downloaded and played' : 'YOUTUBE MUSIC: blocked on this CI machine (bot check)');

      // 3. SoundCloud download: always reachable, proves the whole path.
      final sc = await pcLink.search('lofi hip hop chill beat', source: 'soundcloud');
      say('soundcloud search: ${sc.length} results');
      expect(sc, isNotEmpty);
      var done = false;
      for (final s in sc.take(4)) {
        try {
          if (await saveAndPlay(s, PlaylistInfo(folder: 'SC Test', title: 'SC Test', trackIds: []))) {
            done = true;
            break;
          }
        } on TestFailure catch (e) {
          say('soundcloud song failed, trying next: $e');
        }
      }
      expect(done, isTrue, reason: 'a SoundCloud song must download and play on the phone');
    } finally {
      await dumpLog('end of test');
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
