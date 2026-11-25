import 'dart:async';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'desktop/desktop_shell.dart';
import 'desktop/engine_client.dart';
import 'ui/welcome_screen.dart';
import 'ui/qr.dart';

import 'app_expiry.dart';
import 'app_state.dart';
import 'audio_handler.dart';
import 'ui/menus.dart' show shareSongs;
import 'ui/nearby_ui.dart';
import 'ui/net_jam_ui.dart';
import 'ui/aurora.dart';
import 'ui/common.dart';
import 'ui/lab_screen.dart';
import 'ui/library_screen.dart';
import 'ui/search_screen.dart';
import 'ui/sync_screen.dart';
import 'recognize/recognize_sheet.dart';
import 'ui/trending_view.dart';
import 'ui/update_ui.dart';
import 'windows_media.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized(windows: true);
  }
  await store.load();
  if (!Platform.isWindows) {
    // Lock screen, notification, Bluetooth and car controls (Android Auto lists your playlists).
    await AudioService.init(
      builder: () => SpotVaultAudioHandler(playerService, store),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.spotvault.app.playback',
        androidNotificationChannelName: 'Music playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  }
  darkMode.value = store.darkTheme;
  themeStyle.value = store.themeStyle.isEmpty ? 'minimal' : store.themeStyle;
  if (Platform.isWindows) {
    // The PC downloader runs hidden next to the app; the library is its folder.
    engine.onLibraryChanged = engine.loadLibrary;
    unawaited(engine.start());
  }
  await playerService.init();
  // Windows: show in the Win+A media box and answer the keyboard media keys.
  // (audio_service, used on phones, has no Windows support.)
  if (Platform.isWindows) WindowsMedia(playerService, store).start();
  // Phones nearby: share songs and Jam over the same Wi-Fi.
  nearbyService
    ..onIncomingShare = askIncomingShare
    ..onJoinRequest = askJoin;
  shareSongs = shareFlow;
  nearbyService.start();
  // iPhone only: plan the AltStore refresh reminders (a refresh resets them).
  if (AppExpiry.supported) unawaited(appExpiry.refresh());
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
    textTheme: (p.dark ? Typography.whiteMountainView : Typography.blackMountainView).apply(bodyColor: p.text, displayColor: p.text),
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
    // Cloud look: every button is a pill; filled ones are ink with light text.
    filledButtonTheme: isCloud
        ? FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: kOnInk, shape: const StadiumBorder(), minimumSize: const Size(0, 46)))
        : null,
    elevatedButtonTheme: isCloud
        ? ElevatedButtonThemeData(style: ElevatedButton.styleFrom(backgroundColor: kInk, foregroundColor: kOnInk, elevation: 0, shape: const StadiumBorder()))
        : null,
    outlinedButtonTheme: isCloud
        ? OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: p.text, side: BorderSide(color: p.text), shape: const StadiumBorder()))
        : null,
    textButtonTheme: isCloud ? TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: p.text, shape: const StadiumBorder())) : null,
    chipTheme: isCloud
        ? ChipThemeData(
            shape: StadiumBorder(side: BorderSide(color: p.line)),
            backgroundColor: Colors.transparent,
            selectedColor: kInk,
            labelStyle: TextStyle(color: p.text, fontWeight: FontWeight.w500),
            secondaryLabelStyle: TextStyle(color: kOnInk, fontWeight: FontWeight.w600),
            checkmarkColor: kOnInk,
          )
        : null,
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
    return ListenableBuilder(
      listenable: Listenable.merge([darkMode, themeStyle]),
      builder: (context, _) {
        final dark = darkMode.value;
        final p = pal;
        SystemChrome.setSystemUIOverlayStyle(dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
        return MaterialApp(
          title: 'SpotVault',
          navigatorKey: navKey,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(p),
          themeAnimationDuration: const Duration(milliseconds: 450),
          builder: (context, child) => ThemeRepaint(dark: dark, look: themeStyle.value, child: child!),
          home: const _Start(),
        );
      },
    );
  }
}

/// Screens read the palette directly, so a theme change marks every widget
/// for rebuild (including pushed screens and open sheets).
class ThemeRepaint extends StatefulWidget {
  final bool dark;
  final String look;
  final Widget child;
  const ThemeRepaint({super.key, required this.dark, this.look = '', required this.child});

  @override
  State<ThemeRepaint> createState() => ThemeRepaintState();
}

class ThemeRepaintState extends State<ThemeRepaint> {
  @override
  void didUpdateWidget(ThemeRepaint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dark != widget.dark || oldWidget.look != widget.look) {
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

/// Welcome screen the first time (name and look), then the app.
class _Start extends StatefulWidget {
  const _Start();

  @override
  State<_Start> createState() => _StartState();
}

class _StartState extends State<_Start> {
  @override
  Widget build(BuildContext context) {
    final Widget app = Platform.isWindows ? const DesktopShell() : const HomeShell();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      child: store.themeStyle.isEmpty ? WelcomeScreen(key: const ValueKey('welcome'), onDone: () => setState(() {})) : KeyedSubtree(key: const ValueKey('app'), child: app),
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
    // SpotVault links and QR codes opened from other apps.
    try {
      final links = AppLinks();
      links.getInitialLink().then((u) => u == null ? null : _openLink(u));
      links.uriLinkStream.listen(_openLink);
    } catch (_) {}
  }

  void _openLink(Uri uri) {
    final link = SpotLink.parse(uri.toString());
    final ctx = navKey.currentContext;
    if (link == null || ctx == null) return;
    if (link.kind == 'jam') {
      openJamLink(ctx, link);
    } else if (link.kind == 'netjam') {
      joinNetJam(ctx, link.host);
    } else {
      store.lastHost = link.port == 50505 ? link.host : '${link.host}:${link.port}';
      store.pin = link.pin;
      store.changed();
      currentTab.value = 3;
      syncService.sync(store.lastHost, link.pin);
    }
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
            // Tab numbers stay 0 Home, 1 Search, 2 Studio, 3 Sync; Trending (4) sits
            // between Search and Studio in the bar.
            children: [const LibraryScreen(), const SearchScreen(), const LabScreen(), const SyncScreen(), TrendingView(backend: _trendBackend, actions: [RecognizeButton(backend: _trendBackend)])],
          ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            _GlassNav(
              index: tab,
              onTap: (i) {
                // A preview only makes sense on the Search and Trending tabs.
                if (i != 1 && i != 4) playerService.stopPreview();
                currentTab.value = i;
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Trending and song recognition on phones go through the phone's downloader.
final _trendBackend = PhoneTrendingBackend();

class _GlassNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _GlassNav({required this.index, required this.onTap});

  // (tab number, icon, selected icon, label) in the order shown.
  static const _tabs = [
    (0, Icons.home_outlined, Icons.home_rounded, 'Home'),
    (1, Icons.search_rounded, Icons.manage_search_rounded, 'Search'),
    (4, Icons.local_fire_department_outlined, Icons.local_fire_department_rounded, 'Trending'),
    (2, Icons.tune_outlined, Icons.tune_rounded, 'Studio'),
    (3, Icons.sync_rounded, Icons.sync_rounded, 'Sync'),
  ];
  static final _items = [for (final t in _tabs) (t.$2, t.$3, t.$4)];

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
              for (var k = 0; k < _items.length; k++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: _tabs[k].$1 == index,
                    label: _items[k].$3,
                    child: InkResponse(
                      onTap: () => onTap(_tabs[k].$1),
                      radius: 36,
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOutBack,
                              padding: EdgeInsets.symmetric(horizontal: _tabs[k].$1 == index && !isMinimal ? 18 : 10, vertical: 4),
                              decoration: BoxDecoration(
                                // Minimal: no pill, the active tab is just darker.
                                gradient: _tabs[k].$1 == index && !isMinimal
                                    ? LinearGradient(colors: [kViolet.withValues(alpha: 0.32), kEmber.withValues(alpha: 0.14)])
                                    : null,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Icon(_tabs[k].$1 == index ? _items[k].$2 : _items[k].$1, color: _tabs[k].$1 == index ? (isMinimal ? kText : kAccent) : kMuted, size: 23),
                            ),
                            const SizedBox(height: 3),
                            Text(_items[k].$3,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: _tabs[k].$1 == index ? FontWeight.w700 : FontWeight.w500,
                                  color: _tabs[k].$1 == index ? (isMinimal ? kText : kAccent) : kMuted,
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
