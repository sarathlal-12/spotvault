import 'package:flutter/material.dart';

import 'library_store.dart';
import 'pc_link.dart';
import 'player_service.dart';
import 'sync_service.dart';

/// App-wide services, created once in main().
final LibraryStore store = LibraryStore();
final SyncService syncService = SyncService(store);
final PlayerService playerService = PlayerService(store);
final PcLink pcLink = PcLink(store, syncService)
  ..afterSync = playerService.refreshAfterSync
  ..onReady = playerService.playNext;

/// Lets any screen jump to a bottom-nav tab (0 Home, 1 Search, 2 Lab, 3 Sync).
final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

// ---------------------------------------------------------------------------
// "Aurora" palette: violet + cyan glow, in a dark and a light version.
// ---------------------------------------------------------------------------
class Palette {
  final bool dark;
  final Color bg, surface, card, raised, text, muted, accent, line, track, glass, orbA, orbB;
  const Palette({
    required this.dark,
    required this.bg,
    required this.surface,
    required this.card,
    required this.raised,
    required this.text,
    required this.muted,
    required this.accent,
    required this.line,
    required this.track,
    required this.glass,
    required this.orbA,
    required this.orbB,
  });
}

const Palette kDarkPalette = Palette(
  dark: true,
  bg: Color(0xFF0A0912),
  surface: Color(0xFF15131F),
  card: Color(0xFF1C1929),
  raised: Color(0xFF242036),
  text: Color(0xFFF4F2FA),
  muted: Color(0xFFA29DB8),
  accent: Color(0xFFA78BFA),
  line: Color(0x17FFFFFF),
  track: Color(0x1FFFFFFF),
  glass: Color(0x0DFFFFFF),
  orbA: Color(0x738B5CF6),
  orbB: Color(0x4D22D3EE),
);

const Palette kLightPalette = Palette(
  dark: false,
  bg: Color(0xFFF5F4FA),
  surface: Color(0xFFFFFFFF),
  card: Color(0xFFECE9F5),
  raised: Color(0xFFFFFFFF),
  text: Color(0xFF15121F),
  muted: Color(0xFF5E5873),
  accent: Color(0xFF6D28D9),
  line: Color(0x1A15121F),
  track: Color(0xFFE2DEEE),
  glass: Color(0xB3FFFFFF),
  orbA: Color(0x4D8B5CF6),
  orbB: Color(0x4722D3EE),
);

/// Brand colors that stay the same in both themes.
const Color kViolet = Color(0xFF8B5CF6);
const Color kCyan = Color(0xFF22D3EE);
const Color kPink = Color(0xFFF472B6);
const Color kDanger = Color(0xFFF43F5E);
const LinearGradient kBrandGradient = LinearGradient(colors: [kViolet, kCyan]);

/// The theme in use. Changing it repaints the whole app (see main.dart).
final ValueNotifier<bool> darkMode = ValueNotifier<bool>(true);
Palette get pal => darkMode.value ? kDarkPalette : kLightPalette;

// Short names used across the screens; they follow the current theme.
Color get kAccent => pal.accent;
Color get kBg => pal.bg;
Color get kSurface => pal.surface;
Color get kCard => pal.card;
Color get kRaised => pal.raised;
Color get kMuted => pal.muted;
Color get kText => pal.text;
Color get kLine => pal.line;
