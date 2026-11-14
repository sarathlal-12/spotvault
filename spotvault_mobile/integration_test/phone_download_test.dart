// Runs on a real iPhone simulator / Android emulator (see
// .github/workflows/device-test.yml). Checks that the phone can find, preview,
// download and play a song with no PC: the on-phone Python downloader.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/pc_link.dart';
import 'package:spotvault_mobile/phone_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone finds, previews, downloads and plays a song by itself', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final base = Directory('${docs.path}/sv_it')..createSync(recursive: true);
    store.baseDir = base;
    store.musicDir = Directory('${base.path}/Music')..createSync(recursive: true);
    store.artDir = Directory('${base.path}/art')..createSync(recursive: true);
    store.coverDir = Directory('${base.path}/covers')..createSync(recursive: true);
    store.useBridge = false;

    Future<void> dumpLog(String why) async {
      // ignore: avoid_print
      print('--- $why. Engine log:\n${await PhoneEngine.instance.readLog()}');
    }

    final sw = Stopwatch()..start();
    late List<OnlineSong> results;
    try {
      results = await pcLink.search('Believer Imagine Dragons');
    } catch (e) {
      await dumpLog('search failed: $e');
      rethrow;
    }
    // ignore: avoid_print
    print('engine + search: ${sw.elapsed.inSeconds}s, ${results.length} results; first: ${results.first.title} / ${results.first.artist} / ${results.first.url}');
    expect(results, isNotEmpty);
    expect(results.first.url, contains('music.youtube.com'), reason: 'clean filter: YouTube Music songs come first');

    final song = results.first;
    final uri = await pcLink.previewUri(song);
    final res = await http.get(uri, headers: {'Range': 'bytes=0-1023'}).timeout(const Duration(seconds: 60));
    // ignore: avoid_print
    print('preview: ${res.statusCode} ${res.headers['content-type']} ${res.bodyBytes.length} bytes');
    if (res.statusCode != 206) await dumpLog('preview failed');
    expect(res.statusCode, 206);

    final playlist = PlaylistInfo(folder: 'Phone Test', title: 'Phone Test', trackIds: []);
    sw.reset();
    await pcLink.download(song, playlist);
    final job = pcLink.jobs.last;
    // ignore: avoid_print
    print('download: ${job.state} "${job.message}" in ${sw.elapsed.inSeconds}s');
    if (job.state != DlState.saved) await dumpLog('download failed');
    expect(job.state, DlState.saved);

    final t = store.tracks.values.firstWhere((t) => t.phoneOnly);
    final f = store.localFile(t);
    // ignore: avoid_print
    print('saved: ${t.path} ${f.lengthSync()} bytes, ${t.duration.round()}s, art=${t.hasArt}, title="${t.title}" artist="${t.artist}"');
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(500 * 1024));
    expect(t.duration, greaterThan(60));
    expect(t.hasArt, isTrue);
    expect(store.playlists.single.trackIds, contains(t.id));

    // The phone's own player must be able to play the file (no FFmpeg was used).
    final player = AudioPlayer();
    final d = await player.setFilePath(f.path);
    // ignore: avoid_print
    print('player duration: $d');
    expect(d, isNotNull);
    expect(d!.inSeconds, greaterThan(60));
    await player.seek(Duration(seconds: d.inSeconds ~/ 2));
    await player.dispose();

    // Saving the same song again is recognised.
    await pcLink.download(song, playlist);
    expect(pcLink.jobs.last.message, startsWith('Already in'));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
