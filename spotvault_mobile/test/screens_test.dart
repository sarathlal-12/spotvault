import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/main.dart';
import 'package:spotvault_mobile/ui/library_screen.dart';
import 'package:spotvault_mobile/ui/nearby_ui.dart';
import 'package:spotvault_mobile/ui/sync_screen.dart';
import 'package:spotvault_mobile/ui/track_list_screen.dart';

Widget _wrap(Widget child, bool dark) => MaterialApp(
      theme: buildTheme(dark ? kDarkPalette : kLightPalette),
      home: Scaffold(body: child),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    store.baseDir = Directory.systemTemp.createTempSync('sv_screens');
    store.musicDir = Directory('${store.baseDir.path}/Music')..createSync();
    store.artDir = Directory('${store.baseDir.path}/art')..createSync();
    store.coverDir = Directory('${store.baseDir.path}/covers')..createSync();
    nearbyService.scanning = true; // no network scan in widget tests
  });

  for (final dark in [true, false]) {
    final name = dark ? 'dark' : 'light';

    testWidgets('Sync tab is simple: one button, downloads, More ($name)', (tester) async {
      _phone(tester);
      darkMode.value = dark;
      await tester.pumpWidget(_wrap(const SyncScreen(), dark));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Connect and sync'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pump(const Duration(seconds: 1)); // a scan spinner keeps animating
      expect(find.text('Downloader log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Jam start screen draws ($name)', (tester) async {
      _phone(tester);
      darkMode.value = dark;
      await tester.pumpWidget(MaterialApp(theme: buildTheme(dark ? kDarkPalette : kLightPalette), home: const JamScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Be the speaker'), findsOneWidget);
      expect(find.text('Everyone in sync'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Join by address'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Join by address'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final look in ['crimson', 'minimal'])
    testWidgets('Home with pinned and phone playlists draws ($name, $look)', (tester) async {
      _phone(tester);
      darkMode.value = dark;
      themeStyle.value = look;
      addTearDown(() => themeStyle.value = 'minimal');
      store.tracks
        ..clear()
        ..['a'] = Track(id: 'a', path: 'Mine/a.m4a', title: 'A song with a rather long title', artist: 'Someone', album: '', size: 1, mtime: 0, duration: 120, phoneOnly: true);
      store.playlists = [
        PlaylistInfo(folder: 'Malayalam Melodies of the Nineties', title: 'Malayalam Melodies of the Nineties', trackIds: ['a'], pinned: true),
        PlaylistInfo(folder: 'Mine', title: 'Mine', trackIds: ['a'], phoneOnly: true),
      ];
      await tester.pumpWidget(_wrap(const LibraryScreen(), dark));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Malayalam Melodies of the Nineties'), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
      if (look == 'crimson') {
        expect(find.byTooltip('Jam with friends'), findsOneWidget);
      } else {
        expect(find.text('Start a Jam'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      store.playlists = [];
      store.tracks.clear();
    });
  }

  testWidgets('Playlist page offers its menu and reorder mode', (tester) async {
    _phone(tester);
    darkMode.value = true;
    store.tracks
      ..clear()
      ..['a'] = Track(id: 'a', path: 'Mine/a.m4a', title: 'First', artist: 'X', album: '', size: 1, mtime: 0, duration: 120, phoneOnly: true)
      ..['b'] = Track(id: 'b', path: 'Mine/b.m4a', title: 'Second', artist: 'Y', album: '', size: 1, mtime: 0, duration: 120, phoneOnly: true);
    store.playlists = [PlaylistInfo(folder: 'Mine', title: 'Mine', trackIds: ['a', 'b'], phoneOnly: true)];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(kDarkPalette),
      home: TrackListScreen(title: 'Mine', playlistFolder: 'Mine', source: () => store.tracksOf(store.playlists.first)),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Playlist options'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Reorder songs'), findsOneWidget);
    await tester.tap(find.text('Reorder songs'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
