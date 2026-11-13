import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/main.dart';
import 'package:spotvault_mobile/ui/common.dart';
import 'package:spotvault_mobile/ui/track_list_screen.dart';

Track _track(int i) => Track(
      id: 't$i',
      path: 'Slow songs/song $i.m4a',
      title: 'Song number $i',
      artist: 'A.R. Rahman',
      album: '',
      size: 1000,
      mtime: 0,
      duration: 200,
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    store.baseDir = Directory.systemTemp.createTempSync('sv_mini');
    store.artDir = Directory('${store.baseDir.path}/art');
    store.musicDir = Directory('${store.baseDir.path}/Music');
    store.coverDir = Directory('${store.baseDir.path}/covers');
  });

  for (final dark in [true, false]) {
    testWidgets('mini player keeps its height in a screen bottom bar (${dark ? 'dark' : 'light'})', (tester) async {
      _phone(tester);
      darkMode.value = dark;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(dark ? kDarkPalette : kLightPalette),
        // Same slot the playlist page uses: it offers the whole screen height.
        home: Scaffold(
          body: const Center(child: Text('SONG LIST')),
          bottomNavigationBar: SafeArea(
            child: MiniPlayerBar(
              track: _track(1),
              playing: true,
              liked: false,
              progress: Stream.value(0.4),
              onOpen: () {},
              onNext: () {},
              onPrevious: () {},
              onLike: () {},
              onPlayPause: () {},
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final bar = tester.getRect(find.byType(MiniPlayerBar));
      expect(bar.height, lessThan(110), reason: 'the bar must not stretch over the screen');
      expect(bar.bottom, closeTo(844, 1));
      // The page behind it is visible and not covered.
      final list = tester.getRect(find.text('SONG LIST'));
      expect(list.bottom, lessThan(bar.top));
      expect(find.text('Song number 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('opening a playlist shows its songs', (tester) async {
    _phone(tester);
    darkMode.value = true;
    final songs = [for (var i = 1; i <= 12; i++) _track(i)];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(kDarkPalette),
      home: TrackListScreen(title: 'Slow songs', source: () => songs),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Song number 1'), findsOneWidget);
    expect(find.text('Song number 2'), findsOneWidget);
    expect(find.textContaining('12 songs'), findsOneWidget);
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
