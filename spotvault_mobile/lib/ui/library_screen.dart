import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'common.dart';
import 'track_list_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final empty = store.tracks.isEmpty;
        return CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              backgroundColor: kBg,
              title: const Text('Your Library', style: TextStyle(fontWeight: FontWeight.bold)),
              actions: [
                IconButton(
                  tooltip: 'Sync from PC',
                  icon: const Icon(Icons.sync),
                  onPressed: () => currentTab.value = 2,
                ),
              ],
            ),
            if (empty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.laptop_windows, size: 64, color: kMuted),
                      const SizedBox(height: 16),
                      const Text('No music yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      const Text(
                        'Open SpotVault on your PC, then sync your playlists to this phone over Wi-Fi.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kMuted),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => currentTab.value = 2,
                        icon: const Icon(Icons.sync),
                        label: const Text('Sync from PC'),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 116,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      _QuickCard(
                        icon: Icons.favorite,
                        color: const Color(0xFF5038A0),
                        label: 'Liked Songs',
                        count: store.likedTracks.length,
                        onTap: () => _open(
                          context,
                          TrackListScreen(title: 'Liked Songs', source: () => store.likedTracks, icon: Icons.favorite, allowPcOrder: false),
                        ),
                      ),
                      _QuickCard(
                        icon: Icons.library_music,
                        color: const Color(0xFF1E6B47),
                        label: 'All Songs',
                        count: store.tracks.length,
                        onTap: () => _open(
                          context,
                          TrackListScreen(title: 'All Songs', source: () => store.allTracks, icon: Icons.library_music, allowPcOrder: false),
                        ),
                      ),
                      _QuickCard(
                        icon: Icons.history,
                        color: const Color(0xFF8A4B16),
                        label: 'Recently Played',
                        count: store.recentTracks.length,
                        onTap: () => _open(
                          context,
                          TrackListScreen(title: 'Recently Played', source: () => store.recentTracks, icon: Icons.history),
                        ),
                      ),
                      _QuickCard(
                        icon: Icons.trending_up,
                        color: const Color(0xFF9A1E3C),
                        label: 'Most Played',
                        count: store.mostPlayed.length,
                        onTap: () => _open(
                          context,
                          TrackListScreen(title: 'Most Played', source: () => store.mostPlayed, icon: Icons.trending_up),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text('Playlists from your PC', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
              SliverList.builder(
                itemCount: store.playlists.length,
                itemBuilder: (context, i) {
                  final p = store.playlists[i];
                  final tracks = store.tracksOf(p);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: ArtImage(file: store.coverFor(p), size: 56, radius: 4, fallback: Icons.queue_music),
                    title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('Playlist · ${tracks.length} songs', style: const TextStyle(color: kMuted)),
                    trailing: IconButton(
                      icon: const Icon(Icons.play_circle_fill, color: kAccent, size: 36),
                      onPressed: tracks.isEmpty ? null : () => playerService.playTracks(tracks, shuffle: false),
                    ),
                    onTap: () => _open(
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
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ],
        );
      },
    );
  }
}

class _QuickCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final int count;
  final VoidCallback onTap;

  const _QuickCard({required this.icon, required this.color, required this.label, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Ink(
          width: 140,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.55)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: Colors.white),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('$count songs', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
