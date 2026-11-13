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
// "Crimson" palette: forest-green night, charcoal panels, crimson red and
// sage green, in a dark and a light (ivory) version.
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
  bg: Color(0xFF06110C), // forest green
  surface: Color(0xFF171717), // charcoal black
  card: Color(0xFF1F2421),
  raised: Color(0xFF262B28),
  text: Color(0xFFF2EFE8),
  muted: Color(0xFFA3ADA7),
  accent: Color(0xFFF0605A), // crimson, lightened for text on dark
  line: Color(0x17FFFFFF),
  track: Color(0x1FFFFFFF),
  glass: Color(0x0DFFFFFF),
  orbA: Color(0x80A31C1B),
  orbB: Color(0x403C6E58),
);

const Palette kLightPalette = Palette(
  dark: false,
  bg: Color(0xFFF4F1EA), // ivory
  surface: Color(0xFFFFFFFF),
  card: Color(0xFFE8E2D6),
  raised: Color(0xFFFFFFFF),
  text: Color(0xFF06110C),
  muted: Color(0xFF4F5A54),
  accent: Color(0xFFA31C1B),
  line: Color(0x1A06110C),
  track: Color(0xFFE2DCCF),
  glass: Color(0xB3FFFFFF),
  orbA: Color(0x47E8A8A0),
  orbB: Color(0x4DBED8C8),
);

/// Brand colours that stay the same in both themes.
/// (Names kept from the first design so every screen picks up the new skin.)
const Color kViolet = Color(0xFFA31C1B); // crimson red: buttons, fills, glow
const Color kEmber = Color(0xFFD9443F); // brighter crimson for gradients
const Color kCyan = Color(0xFF9CC5B0); // sage green: second accent
const Color kForest = Color(0xFF2F6B52); // deep green for glows
const Color kPink = Color(0xFFF0605A); // likes and Moments
const Color kDanger = Color(0xFFF43F5E);
const LinearGradient kBrandGradient = LinearGradient(colors: [kViolet, kEmber]);

/// Serif display type, like the brand headline. System fonts only, so the
/// app works offline: Georgia on iPhone, the system serif on Android.
const String kDisplayFont = 'Georgia';
const List<String> kDisplayFallback = ['serif', 'Noto Serif', 'Times New Roman'];

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
