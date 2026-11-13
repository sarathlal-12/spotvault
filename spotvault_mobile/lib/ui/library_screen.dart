import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'aurora.dart';
import 'common.dart';
import 'track_list_screen.dart';

/// Home: continue listening, quick lists and the playlist grid.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Up late';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, playerService]),
      builder: (context, _) {
        final empty = store.tracks.isEmpty;
        return SafeArea(
          bottom: false,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: FadeSlideIn(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_greeting(), style: TextStyle(fontSize: 13, color: kMuted)),
                              const SizedBox(height: 2),
                              Text('Your Vault', style: displayStyle(28)),
                            ],
                          ),
                        ),
                        GlassIconButton(icon: Icons.sync_rounded, tooltip: 'Sync from PC', onPressed: () => currentTab.value = 3),
                        const SizedBox(width: 8),
                        const ThemeToggle(),
                      ],
                    ),
                  ),
                ),
              ),
              if (empty)
                SliverFillRemaining(hasScrollBody: false, child: _EmptyState())
              else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: FadeSlideIn(delay: const Duration(milliseconds: 60), child: _LinkPill()),
                  ),
                ),
                if (playerService.current != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: FadeSlideIn(delay: const Duration(milliseconds: 120), child: _ContinueCard()),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: FadeSlideIn(
                    delay: const Duration(milliseconds: 180),
                    child: SizedBox(
                      height: 58,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        children: [
                          _Chip(
                            icon: Icons.favorite_rounded,
                            label: 'Liked · ${store.likedTracks.length}',
                            onTap: () => _open(context,
                                TrackListScreen(title: 'Liked Songs', source: () => store.likedTracks, icon: Icons.favorite, allowPcOrder: false)),
                          ),
                          _Chip(
                            icon: Icons.library_music_rounded,
                            label: 'All songs · ${store.tracks.length}',
                            onTap: () => _open(context,
                                TrackListScreen(title: 'All Songs', source: () => store.allTracks, icon: Icons.library_music, allowPcOrder: false)),
                          ),
                          _Chip(
                            icon: Icons.history_rounded,
                            label: 'Recent',
                            onTap: () => _open(context,
                                TrackListScreen(title: 'Recently Played', source: () => store.recentTracks, icon: Icons.history)),
                          ),
                          _Chip(
                            icon: Icons.trending_up_rounded,
                            label: 'Most played',
                            onTap: () => _open(context,
                                TrackListScreen(title: 'Most Played', source: () => store.mostPlayed, icon: Icons.trending_up)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                    child: Row(
                      children: [
                        Expanded(child: Text('Your playlists', style: displayStyle(20))),
                        Text('${store.playlists.length}', style: TextStyle(color: kMuted, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: store.playlists.length,
                    itemBuilder: (context, i) {
                      final p = store.playlists[i];
                      return FadeSlideIn(
                        delay: Duration(milliseconds: 220 + 50 * (i < 8 ? i : 8)),
                        child: _PlaylistCard(
                          playlist: p,
                          onOpen: () => _open(
                            context,
                            TrackListScreen(
                              title: p.title,
                              cover: store.coverFor(p),
                              source: () {
                                final cur = store.playlists.where((x) => x.folder == p.folder);
                                return cur.isEmpty ? const <Track>[] : store.tracksOf(cur.first);
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 180)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: FadeSlideIn(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                gradient: const SweepGradient(colors: [kViolet, kEmber, kForest, kViolet]),
                boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.45), blurRadius: 40, offset: const Offset(0, 14))],
              ),
              child: const Icon(Icons.library_music_rounded, size: 44, color: Colors.white),
            ),
            const SizedBox(height: 22),
            Text('No music yet', style: displayStyle(22)),
            const SizedBox(height: 8),
            Text(
              'Open SpotVault on your PC, then sync your playlists to this phone over Wi-Fi.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted, height: 1.4),
            ),
            const SizedBox(height: 22),
            GradientButton(icon: Icons.sync_rounded, label: 'Sync from PC', onTap: () => currentTab.value = 3),
          ],
        ),
      ),
    );
  }
}

class _LinkPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final pc = store.pcName.isEmpty ? 'your PC' : store.pcName;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: pal.dark ? pal.glass : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: kLine),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PulseDot(color: store.lastSync == 0 ? kMuted : kCyan),
            const SizedBox(width: 8),
            Text(
              store.lastSync == 0 ? 'Not synced yet' : 'Linked to $pc · ${store.tracks.length} songs offline',
              style: TextStyle(fontSize: 12, color: kMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = playerService.current!;
    final p = playerService.player;
    return Sheen(
      child: GlassCard(
        radius: 26,
        padding: const EdgeInsets.all(16),
        onTap: () => openNowPlaying(context),
        gradient: LinearGradient(
          colors: pal.dark
              ? [kViolet.withValues(alpha: 0.26), kForest.withValues(alpha: 0.22)]
              : [Colors.white, const Color(0xFFF6E6E2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.45), blurRadius: 26, offset: const Offset(0, 10))],
              ),
              child: Stack(
                children: [
                  TrackArt(t, size: 88, radius: 20),
                  Positioned(left: 8, bottom: 8, child: EqBars(color: Colors.white, height: 16, playing: p.playing)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.playing ? 'NOW PLAYING' : 'CONTINUE LISTENING',
                      style: TextStyle(fontSize: 11, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: kAccent)),
                  const SizedBox(height: 6),
                  Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: displayStyle(19)),
                  const SizedBox(height: 4),
                  Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(height: 10),
                  StreamBuilder<Duration>(
                    stream: p.positionStream,
                    builder: (_, snap) {
                      final total = p.duration?.inMilliseconds ?? 0;
                      final f = total > 0 ? ((snap.data?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0) : 0.0;
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(
                          children: [
                            Container(height: 4, color: pal.track),
                            FractionallySizedBox(
                              widthFactor: f,
                              child: Container(height: 4, decoration: const BoxDecoration(gradient: kBrandGradient)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Chip({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: pal.dark ? pal.glass : pal.surface,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: kLine),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: kAccent),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kText)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final PlaylistInfo playlist;
  final VoidCallback onOpen;
  const _PlaylistCard({required this.playlist, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cover = store.coverFor(playlist);
    final tracks = store.tracksOf(playlist);
    final colors = artColorsFor(playlist.title);
    return Pressable(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                boxShadow: [BoxShadow(color: colors.first.withValues(alpha: 0.30), blurRadius: 22, offset: const Offset(0, 10))],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (cover != null)
                    LayoutBuilder(builder: (_, c) => ArtImage(file: cover, size: c.maxWidth, radius: 0, fallback: Icons.queue_music))
                  else
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _initials(playlist.title),
                          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: -1),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: Pressable(
                      onTap: () {
                        if (tracks.isNotEmpty) playerService.playTracks(tracks, shuffle: false);
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: kBrandGradient,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4))],
                        ),
                        child: Icon(Icons.play_arrow_rounded, color: Colors.white, semanticLabel: 'Play ${playlist.title}'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(playlist.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: kText)),
          Text('${tracks.length} songs', style: TextStyle(fontSize: 12, color: kMuted)),
        ],
      ),
    );
  }

  static String _initials(String title) {
    final words = title.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '♪';
    if (words.length == 1) return words.first.substring(0, words.first.length < 2 ? words.first.length : 2).toUpperCase();
    return (words[0][0] + words[1][0]).toUpperCase();
  }
}
