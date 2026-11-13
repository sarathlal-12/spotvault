import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app_state.dart';
import 'ui/aurora.dart';
import 'ui/common.dart';
import 'ui/lab_screen.dart';
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
  darkMode.value = store.darkTheme;
  await playerService.init();
  runApp(const SpotVaultApp());
}

ThemeData buildTheme(Palette p) {
  final scheme = p.dark
      ? ColorScheme.dark(primary: p.accent, secondary: kCyan, surface: p.surface, onSurface: p.text)
      : ColorScheme.light(primary: p.accent, secondary: const Color(0xFF0E7490), surface: p.surface, onSurface: p.text);
  return ThemeData(
    useMaterial3: true,
    brightness: p.dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: p.bg,
    colorScheme: scheme,
    textTheme: (p.dark ? Typography.whiteMountainView : Typography.blackMountainView)
        .apply(bodyColor: p.text, displayColor: p.text),
    iconTheme: IconThemeData(color: p.text),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.dark ? p.raised : p.text,
      contentTextStyle: TextStyle(color: p.dark ? p.text : p.bg),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    ),
    dialogTheme: DialogThemeData(backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    appBarTheme: AppBarTheme(backgroundColor: p.bg, surfaceTintColor: Colors.transparent, foregroundColor: p.text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.dark ? p.glass : p.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.accent, width: 1.5)),
      labelStyle: TextStyle(color: p.muted),
      hintStyle: TextStyle(color: p.muted),
      prefixIconColor: p.muted,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kViolet : p.track),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}

class SpotVaultApp extends StatelessWidget {
  const SpotVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: darkMode,
      builder: (context, dark, _) {
        final p = dark ? kDarkPalette : kLightPalette;
        SystemChrome.setSystemUIOverlayStyle(dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
        return MaterialApp(
          title: 'SpotVault',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(p),
          themeAnimationDuration: const Duration(milliseconds: 450),
          builder: (context, child) => ThemeRepaint(dark: dark, child: child!),
          home: const HomeShell(),
        );
      },
    );
  }
}

/// Screens read the palette directly, so a theme change marks every widget
/// for rebuild (including pushed screens and open sheets).
class ThemeRepaint extends StatefulWidget {
  final bool dark;
  final Widget child;
  const ThemeRepaint({super.key, required this.dark, required this.child});

  @override
  State<ThemeRepaint> createState() => ThemeRepaintState();
}

class ThemeRepaintState extends State<ThemeRepaint> {
  @override
  void didUpdateWidget(ThemeRepaint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dark != widget.dark) {
      void mark(Element e) {
        e.markNeedsBuild();
        e.visitChildren(mark);
      }

      (context as Element).visitChildren(mark);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
        extendBody: true,
        body: AuroraBackground(
          child: IndexedStack(
            index: tab,
            children: const [LibraryScreen(), SearchScreen(), LabScreen(), SyncScreen()],
          ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            _GlassNav(
              index: tab,
              onTap: (i) {
                // A preview only makes sense on the Search tab.
                if (i != 1) playerService.stopPreview();
                currentTab.value = i;
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _GlassNav({required this.index, required this.onTap});

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.search_rounded, Icons.manage_search_rounded, 'Search'),
    (Icons.science_outlined, Icons.science_rounded, 'Lab'),
    (Icons.sync_rounded, Icons.sync_rounded, 'Sync'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg.withValues(alpha: 0.94),
        border: Border(top: BorderSide(color: kLine)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 66,
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    label: _items[i].$3,
                    child: InkResponse(
                      onTap: () => onTap(i),
                      radius: 36,
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOutBack,
                              padding: EdgeInsets.symmetric(horizontal: i == index ? 18 : 10, vertical: 4),
                              decoration: BoxDecoration(
                                gradient: i == index
                                    ? LinearGradient(colors: [kViolet.withValues(alpha: 0.32), kEmber.withValues(alpha: 0.14)])
                                    : null,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Icon(i == index ? _items[i].$2 : _items[i].$1,
                                  color: i == index ? kAccent : kMuted, size: 23),
                            ),
                            const SizedBox(height: 3),
                            Text(_items[i].$3,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                                  color: i == index ? kAccent : kMuted,
                                )),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
