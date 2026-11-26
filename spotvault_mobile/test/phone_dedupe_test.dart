import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:flutter/material.dart';
import 'package:spotvault_mobile/phone_dedupe.dart';
import 'package:spotvault_mobile/ui/dupes_screen.dart';

Track _song(String id, String title, String artist, List<int> bytes, {double secs = 200, bool phone = true}) {
  final t = Track(
    id: id,
    path: 'Phone/$id.m4a',
    title: title,
    artist: artist,
    album: '',
    size: bytes.length,
    mtime: 0,
    duration: secs,
    phoneOnly: phone,
  );
  File('${store.musicDir.path}/${t.path}')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  store.tracks[id] = t;
  return t;
}

void main() {
  setUp(() {
    store.baseDir = Directory.systemTemp.createTempSync('sv_dupes');
    store.musicDir = Directory('${store.baseDir.path}/Music')..createSync();
    store.artDir = Directory('${store.baseDir.path}/art')..createSync();
    store.coverDir = Directory('${store.baseDir.path}/covers')..createSync();
    store.tracks.clear();
    store.playlists = [];
    store.favorites.clear();
    store.playCounts.clear();
    store.recent = [];
  });

  test('titles match without the extras', () {
    expect(normTitle('Kesariya (From "Brahmastra") [Official Video]'), 'kesariya');
    expect(sameSong('Kesariya', 'Arijit Singh', 268, 'Kesariya (Lyrical)', 'Arijit Singh, Pritam', 270), isTrue);
    expect(sameSong('Kesariya', 'Arijit Singh', 268, 'Kesariya', 'Someone Else', 268), isFalse);
    expect(sameSong('Kesariya', 'Arijit Singh', 268, 'Kesariya', 'Arijit Singh', 300), isFalse); // another version
  });

  test('finds identical and similar copies, keeps the best one', () async {
    final same = List.filled(200000, 7);
    _song('a', 'Tum Hi Ho', 'Arijit Singh', same);
    _song('b', 'Tum Hi Ho (Official Audio)', 'Arijit Singh', same);
    _song('c', 'Kesariya', 'Arijit Singh', List.filled(100000, 1), secs: 268);
    _song('d', 'Kesariya [Lyrical]', 'Arijit Singh', List.filled(300000, 2), secs: 269); // better quality
    _song('e', 'Other Song', 'Someone', List.filled(1000, 3));
    _song('f', 'Tum Hi Ho', 'Arijit Singh', same, phone: false); // from the PC: left alone

    final groups = await findPhoneDupes();
    expect(groups.length, 2);
    final exact = groups.firstWhere((g) => g.exact);
    expect({for (final t in exact.copies) t.id}, {'a', 'b'});
    final near = groups.firstWhere((g) => !g.exact);
    expect(near.keep.id, 'd');
    expect(near.freeBytes, 100000);
  });

  test('merging keeps playlists, likes and plays, deletes the other file', () async {
    final a = _song('a', 'Tum Hi Ho', 'Arijit Singh', List.filled(5000, 7));
    final b = _song('b', 'Tum Hi Ho', 'Arijit Singh', List.filled(5000, 7));
    store.playlists = [
      PlaylistInfo(folder: 'Slow', title: 'Slow', trackIds: ['x', 'b', 'y'], phoneOnly: true),
      PlaylistInfo(folder: 'Hindi', title: 'Hindi', trackIds: ['a', 'b'], phoneOnly: true),
    ];
    store.favorites.add('b');
    store.playCounts['a'] = 2;
    store.playCounts['b'] = 3;
    store.recent = ['b', 'a'];

    final g = (await findPhoneDupes()).single..keep = a;
    final freed = await mergeDupes(g);

    expect(freed, 5000);
    expect(store.tracks.containsKey('b'), isFalse);
    expect(File('${store.musicDir.path}/${b.path}').existsSync(), isFalse);
    expect(File('${store.musicDir.path}/${a.path}').existsSync(), isTrue);
    expect(store.playlists[0].trackIds, ['x', 'a', 'y']); // same place
    expect(store.playlists[1].trackIds, ['a']);
    expect(store.favorites.contains('a'), isTrue);
    expect(store.playCounts['a'], 5);
    expect(store.recent, ['a']);
    expect(await findPhoneDupes(), isEmpty);
  });

  test('a song already on the phone is found before downloading', () {
    _song('a', 'Tum Hi Ho', 'Arijit Singh', List.filled(10, 1), secs: 262);
    expect(songOnPhone('Tum Hi Ho (Official Video)', 'Arijit Singh', 263)?.id, 'a');
    expect(songOnPhone('Tum Hi Ho', 'Arijit Singh', 0)?.id, 'a'); // length unknown
    expect(songOnPhone('Tum Hi Ho', 'Arijit Singh', 400), isNull); // a long version
    expect(songOnPhone('Channa Mereya', 'Arijit Singh', 262), isNull);
  });

  testWidgets('the clean-up screen lists copies and merges them', (tester) async {
    await tester.runAsync(() async {
      final same = List.filled(4000, 7);
      _song('a', 'Tum Hi Ho', 'Arijit Singh', same);
      _song('b', 'Tum Hi Ho', 'Arijit Singh', same);
      _song('c', 'Kesariya', 'Arijit Singh', List.filled(1000, 1), secs: 268);
      _song('d', 'Kesariya (Lyrical)', 'Arijit Singh', List.filled(3000, 2), secs: 269);
    });
    await tester.pumpWidget(const MaterialApp(home: DupesScreen()));
    for (var i = 0; i < 20 && find.text('Merge identical copies').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('Merge identical copies'), findsOneWidget);
    expect(find.text('Same song, downloaded twice'), findsOneWidget);
    await tester.tap(find.text('Merge identical copies'));
    for (var i = 0; i < 20 && store.tracks.length > 3; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(store.tracks.length, 3);
    for (var i = 0; i < 20 && find.text('Merge identical copies').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('Merge identical copies'), findsNothing);
    expect(find.text('Same song, downloaded twice'), findsOneWidget); // still waits for you
  });
}
