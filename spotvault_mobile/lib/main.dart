import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app_state.dart';
import 'ui/common.dart';
import 'ui/library_screen.dart';
import 'ui/search_screen.dart';
import 'ui/sync_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.spotvault.app.playback',
    androidNotificationChannelName: 'Music playback',
    androidNotificationOngoing: true,
  );
  await store.load();
  await playerService.init();
  runApp(const SpotVaultApp());
}

class SpotVaultApp extends StatelessWidget {
  const SpotVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpotVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, secondary: kAccent, surface: kBg),
        appBarTheme: const AppBarTheme(backgroundColor: kBg, surfaceTintColor: Colors.transparent),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.black,
          indicatorColor: Colors.transparent,
          iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Colors.white : kMuted),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => TextStyle(fontSize: 12, color: s.contains(WidgetState.selected) ? Colors.white : kMuted),
          ),
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: currentTab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(
          index: tab,
          children: const [LibraryScreen(), SearchScreen(), SyncScreen()],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => currentTab.value = i,
              height: 64,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
                NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
                NavigationDestination(icon: Icon(Icons.sync), label: 'Sync'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
