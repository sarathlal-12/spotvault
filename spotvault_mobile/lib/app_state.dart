import 'package:flutter/material.dart';

import 'library_store.dart';
import 'player_service.dart';
import 'sync_service.dart';

/// App-wide services, created once in main().
final LibraryStore store = LibraryStore();
final SyncService syncService = SyncService(store);
final PlayerService playerService = PlayerService(store);

/// Lets any screen jump to a bottom-nav tab (0 Library, 1 Search, 2 Sync).
final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

const Color kAccent = Color(0xFF1ED760);
const Color kBg = Color(0xFF121212);
const Color kSurface = Color(0xFF181818);
const Color kCard = Color(0xFF242424);
const Color kMuted = Color(0xFFB3B3B3);
