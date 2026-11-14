import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/nearby.dart';
import 'package:spotvault_mobile/player_service.dart';

LibraryStore _store(String name) {
  final s = LibraryStore();
  s.baseDir = Directory.systemTemp.createTempSync('sv_$name');
  s.musicDir = Directory('${s.baseDir.path}/Music')..createSync();
  s.artDir = Directory('${s.baseDir.path}/art')..createSync();
  s.coverDir = Directory('${s.baseDir.path}/covers')..createSync();
  return s;
}

void main() {
  test('a song and its cover go from one phone to another after Accept', () async {
    final a = _store('a'), b = _store('b');
    final song = Track(id: 'x1', path: 'Hits/Artist - Song.m4a', title: 'Song', artist: 'Artist', album: '', size: 0, mtime: 0, duration: 200, hasArt: true);
    final bytes = List<int>.generate(300000, (i) => i % 251);
    File('${a.musicDir.path}/Hits/Artist - Song.m4a')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    a.artFile(song).writeAsBytesSync([0xFF, 0xD8, 1, 2, 3]);
    a.tracks[song.id] = song;

    final sender = NearbyService(a, PlayerService(a), port: 50531, name: 'Phone A', id: 'a');
    final receiver = NearbyService(b, PlayerService(b), port: 50532, name: 'Phone B', id: 'b');
    await sender.start();
    await receiver.start();
    IncomingShare? asked;
    receiver.onIncomingShare = (s) async {
      asked = s;
      return true;
    };

    final ok = await sender.share(NearbyPhone('127.0.0.1', 50532, 'Phone B', 'b', null), [song]);
    expect(ok, isTrue);
    expect(asked!.fromName, 'Phone A');
    expect(asked!.songs.single.title, 'Song');

    for (var i = 0; i < 50 && (receiver.receiving != null || b.tracks.isEmpty); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final got = b.tracks.values.single;
    expect(got.phoneOnly, isTrue);
    expect(got.title, 'Song');
    expect(b.localFile(got).readAsBytesSync(), bytes);
    expect(got.hasArt, isTrue);
    expect(b.playlists.single.name, 'Shared with me');

    // Without a grant, files can't be fetched.
    final res = await HttpClient().getUrl(Uri.parse('http://127.0.0.1:50531/nearby/file?t=wrong&id=x1')).then((r) => r.close());
    expect(res.statusCode, 403);
  });

  test('a declined share sends nothing', () async {
    final a = _store('c'), b = _store('d');
    final song = Track(id: 'y', path: 'H/S.m4a', title: 'S', artist: '', album: '', size: 0, mtime: 0, duration: 1);
    File('${a.musicDir.path}/H/S.m4a')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    a.tracks['y'] = song;
    final sender = NearbyService(a, PlayerService(a), port: 50533, name: 'A', id: 'c');
    final receiver = NearbyService(b, PlayerService(b), port: 50534, name: 'B', id: 'd');
    await sender.start();
    await receiver.start();
    receiver.onIncomingShare = (_) async => false;
    expect(await sender.share(NearbyPhone('127.0.0.1', 50534, 'B', 'd', null), [song]), isFalse);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(b.tracks, isEmpty);
  });
}
