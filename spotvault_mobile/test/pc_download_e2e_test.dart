import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/pc_link.dart';
import 'package:spotvault_mobile/sync_service.dart';

/// Search, preview and "download through the PC" against a running PC server
/// that has a playlist folder named "Gym". Needs internet. Runs only when
/// SPOTVAULT_TEST_HOST and SPOTVAULT_TEST_PIN are set.
void main() {
  final host = Platform.environment['SPOTVAULT_TEST_HOST'];
  final pin = Platform.environment['SPOTVAULT_TEST_PIN'] ?? '';

  test('phone searches, previews and downloads through the PC', () async {
    final base = await Directory.systemTemp.createTemp('sv_phone_dl');
    final store = LibraryStore()
      ..baseDir = base
      ..musicDir = Directory('${base.path}/Music')
      ..artDir = Directory('${base.path}/art')
      ..coverDir = Directory('${base.path}/covers');
    final sync = SyncService(store);
    final link = PcLink(store, sync);

    // Not paired yet: a clear message, no crash.
    await expectLater(link.search('x'), throwsA(isA<PcException>()));

    await sync.sync(host!, pin);
    expect(sync.state, SyncState.done, reason: sync.message);
    final gym = store.playlists.firstWhere((p) => p.folder == 'Gym');

    final results = await link.search('levitating dua lipa');
    expect(results, isNotEmpty);
    final song = results.first;
    expect(song.title, isNotEmpty);
    expect(song.thumb, startsWith('https://'));

    final preview = await link.previewUri(song);
    final res = await http.get(preview, headers: {'Range': 'bytes=0-65535'});
    expect(res.statusCode, 206);
    expect(res.bodyBytes.length, 65536);

    await link.download(song, gym);
    final job = link.jobFor(song)!;
    expect(job.state, DlState.saved, reason: job.message);
    final arrived = store.tracks.values.where((t) => t.folder == 'Gym').toList();
    expect(arrived, isNotEmpty);
    final t = arrived.first;
    expect(store.localFile(t).lengthSync(), t.size);
    expect(store.playlists.firstWhere((p) => p.folder == 'Gym').trackIds, contains(t.id));
    expect(t.hasArt, isTrue, reason: 'cover art should come along');

    // Asking again for the same song reports it is already there.
    await link.download(song, gym);
    expect(link.jobs.last.state, DlState.saved, reason: link.jobs.last.message);
    expect(link.jobs.last.message, startsWith('Already in'));

    await Future.delayed(const Duration(milliseconds: 300));
    try {
      await base.delete(recursive: true);
    } catch (_) {} // Windows may still hold library.json briefly
  }, skip: host == null ? 'set SPOTVAULT_TEST_HOST and SPOTVAULT_TEST_PIN' : false, timeout: const Timeout(Duration(minutes: 4)));
}
