import 'dart:io';

import 'package:test/test.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/sync_service.dart';

/// End-to-end sync against a running PC server. Runs only when
/// SPOTVAULT_TEST_HOST, SPOTVAULT_TEST_PIN and SPOTVAULT_TEST_DIR are set.
/// No Flutter test binding here: it would block real HTTP.
void main() {
  final host = Platform.environment['SPOTVAULT_TEST_HOST'];
  final pin = Platform.environment['SPOTVAULT_TEST_PIN'] ?? '';
  final dir = Platform.environment['SPOTVAULT_TEST_DIR'];

  test('end-to-end sync with PC server', () async {
    final base = await Directory.systemTemp.createTemp('sv_phone');
    final store = LibraryStore()
      ..baseDir = base
      ..musicDir = Directory('${base.path}/Music')
      ..artDir = Directory('${base.path}/art')
      ..coverDir = Directory('${base.path}/covers');
    final sync = SyncService(store);

    await sync.sync(host!, '000000');
    expect(sync.state, SyncState.error, reason: 'wrong PIN must fail');

    await sync.sync(host, pin);
    expect(sync.state, SyncState.done, reason: sync.message);
    expect(store.playlists.map((p) => p.title).toSet(), {'Gym Beats', 'Chill'});
    expect(store.tracks.length, 3);
    for (final t in store.tracks.values) {
      expect(store.localFile(t).lengthSync(), t.size);
    }
    expect(store.playlists.firstWhere((p) => p.folder == 'Gym').trackIds.length, 2);

    // Second sync copies nothing.
    await sync.sync(host, pin);
    expect(sync.filesTotal, 0);

    // Delete a song on the "PC": phone mirrors it.
    File('$dir/Chill/Calm - Rain.mp3').deleteSync();
    await sync.sync(host, pin);
    expect(sync.removed, 1);
    expect(store.tracks.length, 2);
    expect(store.playlists.firstWhere((p) => p.folder == 'Chill').trackIds, isEmpty);

    // Resume: a half-written .part file is completed with a Range request.
    final t = store.tracks.values.first;
    final f = store.localFile(t);
    final bytes = f.readAsBytesSync();
    f.deleteSync();
    File('${f.path}.part').writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
    await sync.sync(host, pin);
    expect(sync.filesTotal, 1);
    expect(f.readAsBytesSync(), bytes);

    await store.save();
    final reloaded = LibraryStore()..baseDir = base;
    expect(File('${base.path}/library.json').existsSync(), isTrue);
    expect(reloaded.baseDir.path, base.path);
  }, skip: host == null ? 'set SPOTVAULT_TEST_HOST to run' : false);
}
