import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/phone_dedupe.dart';
import 'package:spotvault_mobile/sync_service.dart';

/// A PC song stored twice on the phone (two playlist folders) is merged on the
/// phone, and the next PC sync keeps it merged: no new download, and the kept
/// copy stays in both playlists. Uses a small fake PC server.
/// (No Flutter test binding here: it would block real HTTP.)
void main() {
  test('a merge of PC songs survives the next sync', () async {
    final song = List<int>.generate(50000, (i) => i % 251);
    Map<String, dynamic> t(String id, String path) =>
        {'id': id, 'path': path, 'file': path.split('/').last, 'title': 'Tum Hi Ho', 'artist': 'Arijit Singh', 'size': song.length, 'mtime': 1, 'duration': 262};
    final library = {
      'name': 'Test PC',
      'playlists': [
        {'folder': 'Hindi', 'title': 'Hindi', 'has_cover': false, 'tracks': [t('h1', 'Hindi/Tum Hi Ho.m4a')]},
        {'folder': 'Slow songs', 'title': 'Slow songs', 'has_cover': false, 'tracks': [t('s1', 'Slow songs/Tum Hi Ho.m4a')]},
      ],
    };
    var fileRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final r = req.response;
      switch (req.uri.path) {
        case '/api/status':
          r.write(jsonEncode({'app': 'SpotVault'}));
        case '/api/library':
          r.write(jsonEncode(library));
        case '/api/file':
          fileRequests++;
          r.add(song);
        default:
          r.statusCode = 404;
      }
      await r.close();
    });
    addTearDown(() => server.close(force: true));

    final base = await Directory.systemTemp.createTemp('sv_merge');
    final store = LibraryStore()
      ..baseDir = base
      ..musicDir = Directory('${base.path}/Music')
      ..artDir = Directory('${base.path}/art')
      ..coverDir = Directory('${base.path}/covers');
    store.musicDir.createSync();
    store.artDir.createSync();
    store.coverDir.createSync();
    final sync = SyncService(store);
    final host = '127.0.0.1:${server.port}';

    await sync.sync(host, '1234');
    expect(sync.state, SyncState.done, reason: sync.message);
    expect(store.tracks.keys.toSet(), {'h1', 's1'});
    expect(fileRequests, 2);

    // Clean up duplicates on the phone.
    debugDedupeOnWindows = true;
    final groups = await findPhoneDupes(store);
    expect(groups.length, 1);
    expect(groups.single.exact, isTrue);
    final g = groups.single..keep = store.tracks['h1']!;
    await mergeDupes(g, store);
    expect(store.tracks.keys, ['h1']);
    expect(store.mergedInto, {'s1': 'h1'});
    expect(store.playlistByFolder('Slow songs')!.trackIds, ['h1']);

    // Next PC sync: nothing downloaded again, both playlists still have the song.
    fileRequests = 0;
    await sync.sync(host, '1234');
    expect(sync.state, SyncState.done, reason: sync.message);
    expect(fileRequests, 0);
    expect(store.tracks.keys, ['h1']);
    expect(store.playlistByFolder('Hindi')!.trackIds, ['h1']);
    expect(store.playlistByFolder('Slow songs')!.trackIds, ['h1']);

    // The merge is saved with the library.
    await store.save();
    final saved = jsonDecode(File('${base.path}/library.json').readAsStringSync()) as Map<String, dynamic>;
    expect(saved['mergedInto'], {'s1': 'h1'});

    // If the kept copy is gone, the merge no longer applies and the song comes back.
    store.localFile(store.tracks['h1']!).deleteSync();
    expect(store.keptFor('s1'), isNull);
  });
}
