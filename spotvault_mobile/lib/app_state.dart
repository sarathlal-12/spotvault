import 'package:flutter/material.dart';

import 'library_store.dart';
import 'pc_link.dart';
import 'player_service.dart';
import 'sync_service.dart';

/// App-wide services, created once in main().
final LibraryStore store = LibraryStore();
final SyncService syncService = SyncService(store);
final PlayerService playerService = PlayerService(store);
final PcLink pcLink = PcLink(store, syncService)..afterSync = playerService.refreshAfterSync;

/// Lets any screen jump to a bottom-nav tab (0 Library, 1 Search, 2 Sync).
final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

// "Midnight violet" palette, shared with the Windows app and website.
const Color kAccent = Color(0xFF8B5CF6);
const Color kAccentDeep = Color(0xFF6366F1);
const Color kBg = Color(0xFF0B0B14);
const Color kSurface = Color(0xFF14142A);
const Color kCard = Color(0xFF1C1C36);
const Color kRaised = Color(0xFF26264A);
const Color kMuted = Color(0xFF9A9AC0);
