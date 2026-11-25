// Renders the 2.3 screens for a visual check:
//   flutter test test_shots/v23_test.dart --update-goldens  ->  test_shots/out/v23/*.png
import 'dart:async';
// ignore_for_file: unused_import, invalid_use_of_visible_for_testing_member
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
import 'package:spotvault_mobile/ui/nearby_ui.dart';
import 'package:spotvault_mobile/ui/net_jam_ui.dart';
import 'package:spotvault_mobile/ui/now_playing_screen.dart';
import 'package:spotvault_mobile/ui/search_screen.dart';
import 'package:spotvault_mobile/ui/track_list_screen.dart';
import 'package:spotvault_mobile/ui/welcome_screen.dart';
import 'package:spotvault_mobile/ui/trending_view.dart';
import 'package:spotvault_mobile/ui/mix_sheet.dart';
import 'package:spotvault_mobile/recognize/recognize_sheet.dart';
import 'package:spotvault_mobile/desktop/desktop_pages.dart';
import 'package:flutter/scheduler.dart';

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
    themeStyle.value = 'minimal';
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
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/v23/$name-${dark ? 'dark' : 'light'}.png'));
  }

  _tests(shot);
}

class _FakeTrends implements TrendingBackend {
  @override
  Future<Map<String, dynamic>> load(String country, String chart) async => {
        'charts': [
          {'id': 'apple', 'title': 'Apple Music Top 50'},
          {'id': 'yt:1', 'title': 'Trending 20 India'},
          {'id': 'yt:2', 'title': 'Top Weekly Videos Hindi'},
        ],
        'songs': [for (var i = 0; i < 10; i++) {'title': _titles[i % 8], 'artist': _artists[i % 5], 'art': '', 'url': ''}],
      };
  @override
  Future<Uri> previewUri(Map<String, dynamic> song) async => Uri();
  @override
  Future<void> save(BuildContext context, Map<String, dynamic> song) async {}
}

void _tests(Future<void> Function(WidgetTester, Widget, String, {required bool dark, Size size, void Function()? after}) shot) {
  testWidgets('phone trending', (t) => shot(t, Scaffold(body: TrendingView(backend: _FakeTrends(), actions: [RecognizeButton(backend: _FakeTrends())])), 'phone-trending', dark: true));
  testWidgets('phone trending light', (t) => shot(t, Scaffold(body: TrendingView(backend: _FakeTrends(), actions: [RecognizeButton(backend: _FakeTrends())])), 'phone-trending', dark: false));
  testWidgets('phone player classic', (t) async {
    playerService.debugCurrent = store.tracks['t3'];
    addTearDown(() => playerService.debugCurrent = null);
    await shot(t, const NowPlayingScreen(), 'phone-player', dark: true);
  });
  testWidgets('phone player focus', (t) async {
    store.playerLook = 'focus';
    playerService.debugCurrent = store.tracks['t3'];
    addTearDown(() {
      store.playerLook = 'classic';
      playerService.debugCurrent = null;
    });
    await shot(t, const NowPlayingScreen(), 'phone-focus', dark: false);
  });
  testWidgets('mix sheet', (t) async {
    await shot(t, Scaffold(body: Builder(builder: (c) {
      SchedulerBinding.instance.addPostFrameCallback((_) => showMixSheet(c));
      return const SizedBox.expand();
    })), 'phone-mix', dark: true);
  });
  testWidgets('recognize sheet', (t) async {
    await shot(t, Scaffold(body: Builder(builder: (c) {
      SchedulerBinding.instance.addPostFrameCallback((_) => showRecognizeSheet(c, _FakeTrends()));
      return const SizedBox.expand();
    })), 'phone-recognize', dark: true);
  });
  testWidgets('windows trending', (t) => shot(t, const DesktopShell(), 'desktop-trending', dark: true, size: const Size(1440, 900), after: () => dPage.value = DPage.trending));
  testWidgets('windows settings', (t) async {
    dPage.value = DPage.settings;
    addTearDown(() => dPage.value = DPage.home);
    await shot(t, const DesktopShell(), 'desktop-settings', dark: true, size: const Size(1440, 1500));
  });
}
