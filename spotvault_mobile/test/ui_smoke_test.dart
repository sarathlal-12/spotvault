import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/app_state.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/main.dart';
import 'package:spotvault_mobile/ui/lab_screen.dart';
import 'package:spotvault_mobile/ui/library_screen.dart';

Widget _wrap(Widget child, bool dark) => MaterialApp(
      theme: buildTheme(dark ? kDarkPalette : kLightPalette),
      home: Scaffold(body: child),
    );

void main() {
  for (final dark in [true, false]) {
    final name = dark ? 'dark' : 'light';

    testWidgets('Home (empty library) draws in $name theme', (tester) async {
      darkMode.value = dark;
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(const LibraryScreen(), dark));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Your Vault'), findsOneWidget);
      expect(find.text('No music yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Vault Lab draws in $name theme', (tester) async {
      darkMode.value = dark;
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      store.listenDays[LibraryStore.dayKey(DateTime.now())] = 3 * 3600 * 1000;
      store.listenArtists['Govind Vasantha'] = 3 * 3600 * 1000;
      await tester.pumpWidget(_wrap(const LabScreen(), dark));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Vault Lab'), findsOneWidget);
      expect(find.textContaining('Govind Vasantha', findRichText: true), findsOneWidget);
      expect(find.text('Smart Sleep'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Theme button switches dark and light without errors', (tester) async {
    store.baseDir = Directory.systemTemp.createTempSync('sv_theme');
    darkMode.value = true;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ValueListenableBuilder<bool>(
      valueListenable: darkMode,
      builder: (_, dark, __) => MaterialApp(
        theme: buildTheme(dark ? kDarkPalette : kLightPalette),
        builder: (_, child) => ThemeRepaint(dark: dark, child: child!),
        home: const Scaffold(body: LabScreen()),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Switch to light theme'));
    await tester.pump(const Duration(seconds: 1));
    expect(darkMode.value, isFalse);
    expect(find.byTooltip('Switch to dark theme'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to dark theme'));
    await tester.pump(const Duration(seconds: 1));
    expect(darkMode.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('Moments are kept sorted and close duplicates are ignored', () {
    final s = LibraryStore()..baseDir = Directory.systemTemp.createTempSync('sv_test');
    expect(s.addMoment('a', 50000), isTrue);
    expect(s.addMoment('a', 10000), isTrue);
    expect(s.addMoment('a', 11000), isFalse);
    expect(s.momentsOf('a'), [10000, 50000]);
  });
}
