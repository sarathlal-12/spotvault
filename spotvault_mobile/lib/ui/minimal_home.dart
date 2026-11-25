import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'aurora.dart';
import 'common.dart';
import 'menus.dart';
import 'mix_sheet.dart';
import 'nearby_ui.dart';
import 'track_list_screen.dart';
import 'welcome_screen.dart' show SpotVaultMark;

/// Home in the Minimal look (the 2.0 design): calm, lots of space, big covers.
class MinimalHome extends StatelessWidget {
  const MinimalHome({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  void _openPlaylist(BuildContext context, PlaylistInfo p) => _open(
        context,
        TrackListScreen(
          title: p.name,
          playlistFolder: p.folder,
          cover: store.coverFor(p),
          source: () {
            final cur = store.playlists.where((x) => x.folder == p.folder);
            return cur.isEmpty ? const <Track>[] : store.tracksOf(cur.first);
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, playerService]),
      builder: (context, _) {
        final p = pal;
        final name = store.userName.trim();
        final lists = store.sortedPlaylists;
        final recent = store.recentTracks.take(6).toList();
        return SafeArea(
          bottom: false,
          child: CustomScrollView(slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              sliver: SliverList.list(children: [
                // Header: logo, greeting with your name, look and Jam buttons.
                FadeSlideIn(
                  child: Row(children: [
                    const SpotVaultMark(size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(greeting(), style: TextStyle(fontSize: 13, color: p.muted)),
                        Text(name.isEmpty ? 'Your Vault' : name,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: p.text)),
                      ]),
                    ),
                    _RoundButton(icon: p.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, label: 'Light or dark', onTap: () => setDarkMode(!p.dark)),
                    const SizedBox(width: 8),
                    _RoundButton(icon: Icons.sync_rounded, label: 'Sync', onTap: () => currentTab.value = 3),
                  ]),
                ),
                const SizedBox(height: 22),
                // Start a Jam.
                FadeSlideIn(
                  delay: const Duration(milliseconds: 60),
                  child: _InkCard(
                    onTap: () => openJam(context),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: isCloud ? p.bg : const Color(0xFFE0403B), shape: BoxShape.circle),
                        child: Icon(Icons.groups_rounded, color: isCloud ? p.text : Colors.white, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(nearbyService.inJam ? 'Back to your Jam' : 'Start a Jam',
                              style: TextStyle(color: p.bg, fontSize: 15, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text('Same Wi-Fi, join by QR code', style: TextStyle(color: p.bg.withValues(alpha: 0.7), fontSize: 12)),
                        ]),
                      ),
                      Icon(Icons.chevron_right_rounded, color: p.bg),
                    ]),
                  ),
                ),
                const NearbyStatusCard(),
                const SizedBox(height: 18),
                // Quick lists.
                FadeSlideIn(
                  delay: const Duration(milliseconds: 100),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: Row(children: [
                      _Pill('Liked · ${store.likedTracks.length}', Icons.favorite_border_rounded,
                          () => _open(context, TrackListScreen(title: 'Liked Songs', source: () => store.likedTracks, icon: Icons.favorite, allowPcOrder: false))),
                      _Pill('All songs · ${store.tracks.length}', Icons.library_music_outlined,
                          () => _open(context, TrackListScreen(title: 'All Songs', source: () => store.allTracks, icon: Icons.library_music, allowPcOrder: false))),
                      _Pill('Mix playlists', Icons.shuffle_rounded, () => showMixSheet(context)),
                      _Pill('Most played', Icons.trending_up_rounded,
                          () => _open(context, TrackListScreen(title: 'Most Played', source: () => store.mostPlayed, icon: Icons.trending_up))),
                    ]),
                  ),
                ),
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(child: splitTitle('Your playlists', TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text))),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.line),
                      shape: const StadiumBorder(),
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    onPressed: () => createPlaylistFlow(context),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('New', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 14),
              ]),
            ),
            if (lists.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text('Sync your playlists from your PC, or find songs on the Search tab.', style: TextStyle(color: p.muted)),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: 0.76),
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return FadeSlideIn(
                      delay: Duration(milliseconds: 140 + 40 * (i < 8 ? i : 8)),
                      child: Pressable(
                        onTap: () => _openPlaylist(context, pl),
                        onLongPress: () => showPlaylistMenu(context, pl),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: LayoutBuilder(builder: (c, b) => ArtImage(file: store.coverFor(pl), size: b.maxWidth, radius: 20, fallback: Icons.queue_music_rounded)),
                          ),
                          const SizedBox(height: 8),
                          Row(children: [
                            if (pl.pinned) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.push_pin_rounded, size: 13, color: p.muted)),
                            Expanded(child: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: p.text))),
                          ]),
                          Text('${pl.trackIds.length} songs', style: TextStyle(fontSize: 12, color: p.muted)),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            if (recent.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 6),
                sliver: SliverToBoxAdapter(child: splitTitle('Recently played', TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text))),
              ),
              SliverList.builder(
                itemCount: recent.length,
                itemBuilder: (context, i) => TrackTile(track: recent[i], list: recent, index: i),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 180)),
          ]),
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: Pressable(
            onTap: onTap,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: pal.line)),
              child: Icon(icon, size: 19, color: pal.text),
            ),
          ),
        ),
      );
}

/// The black (in dark: light) card used for "Start a Jam".
class _InkCard extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _InkCard({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: pal.text, borderRadius: BorderRadius.circular(22)),
          child: child,
        ),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _Pill(this.label, this.icon, this.onTap);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Pressable(
          onTap: onTap,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(99), border: Border.all(color: pal.line)),
            child: Row(children: [
              Icon(icon, size: 16, color: pal.text),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.text)),
            ]),
          ),
        ),
      );
}
