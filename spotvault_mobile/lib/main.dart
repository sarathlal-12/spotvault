import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app_state.dart';
import 'ui/common.dart';
import 'ui/library_screen.dart';
import 'ui/search_screen.dart';
import 'ui/sync_screen.dart';
import 'ui/update_ui.dart';

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
        colorScheme: const ColorScheme.dark(primary: kAccent, secondary: kAccentDeep, surface: kBg),
        snackBarTheme: const SnackBarThemeData(backgroundColor: kRaised, contentTextStyle: TextStyle(color: Colors.white)),
        bottomSheetTheme: const BottomSheetThemeData(backgroundColor: kSurface),
        dialogTheme: const DialogThemeData(backgroundColor: kSurface),
        progressIndicatorTheme: const ProgressIndicatorThemeData(color: kAccent),
        appBarTheme: const AppBarTheme(backgroundColor: kBg, surfaceTintColor: Colors.transparent),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF08080F),
          indicatorColor: kAccent.withValues(alpha: 0.18),
          iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? kAccent : kMuted),
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

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  @override
  void initState() {
    super.initState();
    // Quiet update check shortly after start; only speaks up if there is one.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) runUpdateCheck(context, manual: false);
    });
  }

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
              onDestinationSelected: (i) {
                // A preview only makes sense on the Search tab.
                if (i != 1) playerService.stopPreview();
                currentTab.value = i;
              },
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
