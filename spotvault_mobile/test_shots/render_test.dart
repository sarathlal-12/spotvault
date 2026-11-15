// Renders the Minimal screens to PNGs for a visual check:
//   flutter test test_shots --update-goldens   ->  test_shots/out/*.png
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/main.dart';
import 'package:spotvault_mobile/ui/lab_screen.dart';
import 'package:spotvault_mobile/ui/library_screen.dart';
import 'package:spotvault_mobile/ui/track_list_screen.dart';
import 'package:spotvault_mobile/ui/welcome_screen.dart';

const _fonts = 'G:/APPS/flutter/bin/cache/artifacts/material_fonts';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

Track _t(int i) => Track(id: 't$i', path: 'Drive mix/$i.m4a', title: ['Midnight Drive', 'Slow Motion', 'Neon Rain', 'Highway Hum', 'Golden Hour', 'Paper Planes'][i % 6], artist: ['Night Cassette', 'Low Tide', 'Mira Vale'][i % 3], album: '', size: 1, mtime: 0, duration: 200.0 + i, addedAt: i);

void main() {
  setUpAll(() async {
    await _font('Roboto', ['$_fonts/roboto-regular.ttf', '$_fonts/roboto-medium.ttf', '$_fonts/roboto-bold.ttf', '$_fonts/roboto-black.ttf']);
    await _font('MaterialIcons', ['$_fonts/materialicons-regular.otf']);
    store.baseDir = Directory.systemTemp.createTempSync('sv_shots');
    store.musicDir = Directory('${store.baseDir.path}/Music')..createSync();
    store.artDir = Directory('${store.baseDir.path}/art')..createSync();
    store.coverDir = Directory('${store.baseDir.path}/covers')..createSync();
    nearbyService.scanning = true;
    for (var i = 0; i < 8; i++) {
      final t = _t(i);
      store.tracks[t.id] = t;
    }
    store.playlists = [
      for (final n in ['Liked songs', 'Drive mix', 'Late night lo-fi', 'Gym rotation']) PlaylistInfo(folder: n, title: n, trackIds: [for (var i = 0; i < 8; i++) 't$i']),
    ];
    store.recent = ['t0', 't1', 't2'];
    store.userName = 'Sarath';
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    Future<void> shot(WidgetTester tester, Widget w, String name) async {
      tester.view.physicalSize = const Size(390 * 2, 844 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      darkMode.value = dark;
      themeStyle.value = 'minimal';
      await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(pal).copyWith(textTheme: buildTheme(pal).textTheme.apply(fontFamily: 'Roboto')), home: Scaffold(body: w)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-$mode.png'));
    }

    testWidgets('home $mode', (t) => shot(t, const LibraryScreen(), 'home'));
    testWidgets('playlist $mode', (t) => shot(t, TrackListScreen(title: 'Drive mix', playlistFolder: 'Drive mix', source: () => store.tracksOf(store.playlists[1])), 'playlist'));
    testWidgets('studio $mode', (t) => shot(t, const LabScreen(), 'studio'));
    testWidgets('welcome $mode', (t) => shot(t, WelcomeScreen(onDone: () {}), 'welcome'));
  }
}
