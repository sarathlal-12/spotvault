import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';

Track _t(String id, {bool phone = false, String folder = 'Hits'}) => Track(
      id: id,
      path: '$folder/$id.m4a',
      title: 'Song $id',
      artist: 'Artist',
      album: '',
      size: 10,
      mtime: 0,
      duration: 100,
      phoneOnly: phone,
    );

void main() {
  setUp(() {
    store.baseDir = Directory.systemTemp.createTempSync('sv_edits');
    store.musicDir = Directory('${store.baseDir.path}/Music')..createSync();
    store.artDir = Directory('${store.baseDir.path}/art')..createSync();
    store.coverDir = Directory('${store.baseDir.path}/covers')..createSync();
    store.tracks.clear();
    store.playlists = [];
    store.excludedTracks.clear();
    store.excludedFolders.clear();
    store.pcDeletePaths.clear();
    store.pcDeleteFolders.clear();
  });

  test('phone edits to a PC playlist survive the next sync', () {
    final old = PlaylistInfo(folder: 'Hits', title: 'Hits', trackIds: ['a', 'b', 'c'])
      ..pinned = true
      ..customTitle = 'My Hits';
    store.playlists = [old];
    for (final id in ['a', 'b', 'c', 'x']) {
      store.tracks[id] = _t(id);
    }
    store.setPlaylistOrder(old, ['c', 'a', 'b']);
    store.removeFromPlaylist(old, 'b');
    store.addToPlaylist(old, store.tracks['x']!); // from another playlist

    // The PC sends the playlist again with its own order and a new song.
    final fresh = PlaylistInfo(folder: 'Hits', title: 'Hits', trackIds: ['a', 'b', 'c', 'd']);
    fresh.takeEditsFrom(old);

    expect(fresh.name, 'My Hits');
    expect(fresh.pinned, isTrue);
    expect(fresh.trackIds, ['c', 'a', 'x', 'd'], reason: 'phone order, added song kept, removed song stays out, new song appended');
  });

  test('remove from phone keeps PC songs away; delete everywhere queues the PC', () async {
    store.tracks['p1'] = _t('p1');
    store.tracks['p2'] = _t('p2');
    store.tracks['m1'] = _t('m1', phone: true, folder: 'Mine');
    store.playlists = [PlaylistInfo(folder: 'Hits', title: 'Hits', trackIds: ['p1', 'p2', 'm1'])];

    await store.removeSongs(['p1']);
    await store.removeSongs(['p2'], alsoPc: true);
    await store.removeSongs(['m1'], alsoPc: true);

    expect(store.tracks, isEmpty);
    expect(store.excludedTracks, {'p1', 'p2'}, reason: 'phone-only songs need no exclusion');
    expect(store.pcDeletePaths, {'Hits/p2.m4a'});
    expect(store.playlists.single.trackIds, isEmpty);
  });

  test('deleting a playlist removes only songs no other playlist has', () async {
    store.tracks['a'] = _t('a');
    store.tracks['b'] = _t('b');
    final hits = PlaylistInfo(folder: 'Hits', title: 'Hits', trackIds: ['a', 'b']);
    final chill = PlaylistInfo(folder: 'Chill', title: 'Chill', trackIds: ['b']);
    store.playlists = [hits, chill];

    await store.deletePlaylist(hits, alsoPc: true);

    expect(store.playlists.map((p) => p.folder), ['Chill']);
    expect(store.tracks.keys, ['b']);
    expect(store.excludedFolders, {'Hits'});
    expect(store.pcDeleteFolders, {'Hits'});
  });

  test('new phone playlists get unique names and pinned ones sort first', () {
    final a = store.createPlaylist('Road trip');
    final b = store.createPlaylist('Road trip');
    expect(a.folder, 'Road trip');
    expect(b.folder, 'Road trip 2');
    expect(a.phoneOnly, isTrue);
    store.setPinned(b, true);
    expect(store.sortedPlaylists.first.folder, 'Road trip 2');
  });
}
