// Renders the Cloud look (2.2.1) for a visual check:
//   flutter test test_shots/cloud_test.dart --update-goldens  ->  test_shots/out/cloud/*.png
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/desktop/desktop_shell.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/main.dart';
import 'package:spotvault_mobile/net_jam.dart';
import 'package:spotvault_mobile/ui/lab_screen.dart';
import 'package:spotvault_mobile/ui/common.dart';
import 'package:spotvault_mobile/ui/library_screen.dart';
import 'package:spotvault_mobile/ui/minimal_home.dart';
import 'package:spotvault_mobile/ui/car_mode.dart';
import 'package:spotvault_mobile/ui/nearby_ui.dart';
import 'package:spotvault_mobile/ui/net_jam_ui.dart';
import 'package:spotvault_mobile/ui/now_playing_screen.dart';
import 'package:spotvault_mobile/ui/search_screen.dart';
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

const _titles = ['Midnight Drive', 'Slow Motion', 'Neon Rain', 'Highway Hum', 'Golden Hour', 'Paper Planes', 'City Lights', 'Ocean Eyes'];
const _artists = ['Night Cassette', 'Low Tide', 'Mira Vale', 'The Static', 'Juno Bay'];

Track _t(int i) => Track(
      id: 't$i',
      path: 'Drive mix/$i.m4a',
      title: _titles[i % 8],
      artist: _artists[i % 5],
      album: '',
      size: 1,
      mtime: 0,
      duration: 200.0 + i * 7,
      addedAt: i,
      hasArt: true,
    );

void main() {
  setUpAll(() async {
    await _font('Roboto', ['$_fonts/roboto-regular.ttf', '$_fonts/roboto-medium.ttf', '$_fonts/roboto-bold.ttf', '$_fonts/roboto-black.ttf']);
    await _font('MaterialIcons', ['$_fonts/materialicons-regular.otf']);
    await _font('Georgia', ['C:/Windows/Fonts/georgia.ttf', 'C:/Windows/Fonts/georgiab.ttf']);
    store.baseDir = Directory.systemTemp.createTempSync('sv_promo');
    store.musicDir = Directory('${store.baseDir.path}/Music')..createSync();
    store.artDir = Directory('${store.baseDir.path}/art')..createSync();
    store.coverDir = Directory('${store.baseDir.path}/covers')..createSync();
    nearbyService.scanning = true;
    nearbyService.reachable = true;
    for (var i = 0; i < 8; i++) {
      final t = _t(i);
      store.tracks[t.id] = t;
      File('test_shots/promo_art/c$i.png').copySync(store.artFile(t).path);
      store.localFile(t)
        ..createSync(recursive: true)
        ..writeAsBytesSync([0]);
    }
    store.playlists = [
      for (final (i, n) in ['Liked songs', 'Drive mix', 'Late night lo-fi', 'Gym rotation'].indexed)
        PlaylistInfo(folder: n, title: n, trackIds: [for (var k = 0; k < 8; k++) 't${(k + i * 2) % 8}']),
    ];
    store.recent = ['t5', 't1', 't2'];
    store.userName = 'Sarath';
    store.deviceName = 'Sarath';
    store.favorites.addAll(['t0', 't3', 't5']);
    store.recentSearches = [
      for (final (t, a, d) in [('Blinding Lights', 'The Weeknd', '3:20'), ('Pasoori', 'Ali Sethi, Shae Gill', '3:44'), ('Kesariya', 'Arijit Singh', '4:28'), ('Levitating', 'Dua Lipa', '3:23'), ('Heat Waves', 'Glass Animals', '3:58')])
        {'title': t, 'artist': a, 'duration': d, 'url': 'https://music.youtube.com/watch?v=$t', 'thumb': ''},
    ];
  });

  Future<void> shot(WidgetTester tester, Widget w, String name, {required bool dark, Size size = const Size(390, 844), void Function()? after}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    darkMode.value = dark;
    themeStyle.value = 'cloud';
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(pal).copyWith(textTheme: buildTheme(pal).textTheme.apply(fontFamily: 'Roboto')),
      home: w,
    ));
    after?.call();
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/cloud/$name-${dark ? 'dark' : 'light'}.png'));
  }

  for (final dark in [false, true]) {
    testWidgets('home $dark', (t) => shot(t, const Scaffold(body: MinimalHome()), 'home', dark: dark));
    testWidgets('playlist $dark', (t) {
      final p = store.playlists[1];
      return shot(t, TrackListScreen(title: p.name, playlistFolder: p.folder, source: () => store.tracksOf(p)), 'playlist', dark: dark);
    });
    testWidgets('player classic $dark', (t) async {
      playerService.debugCurrent = store.tracks['t3'];
      addTearDown(() => playerService.debugCurrent = null);
      await shot(t, const NowPlayingScreen(), 'player-classic', dark: dark);
    });
    testWidgets('player focus $dark', (t) async {
      store.playerLook = 'focus';
      playerService.debugCurrent = store.tracks['t3'];
      addTearDown(() {
        store.playerLook = 'classic';
        playerService.debugCurrent = null;
      });
      await shot(t, const NowPlayingScreen(), 'player-focus', dark: dark);
    });
    testWidgets('search $dark', (t) => shot(t, const Scaffold(body: SearchScreen()), 'search', dark: dark));
    testWidgets('studio $dark', (t) => shot(t, const Scaffold(body: LabScreen()), 'studio', dark: dark, size: const Size(390, 1400)));
    testWidgets('look card $dark', (t) => shot(t, const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: LookCard())), 'lookcard', dark: dark, size: const Size(390, 400)));
  }
}
