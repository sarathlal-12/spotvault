import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'aurora.dart';
import 'now_playing_screen.dart';

/// Square artwork with a music-note fallback.
class ArtImage extends StatelessWidget {
  final File? file;
  final double size;
  final double radius;
  final IconData fallback;

  const ArtImage({super.key, required this.file, required this.size, this.radius = 6, this.fallback = Icons.music_note});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [kViolet.withValues(alpha: 0.55), kCyan.withValues(alpha: 0.35)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(fallback, color: Colors.white.withValues(alpha: 0.9), size: size * 0.42),
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: file == null
          ? placeholder
          : Image.file(
              file!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * dpr).round(),
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => placeholder,
            ),
    );
  }
}

class TrackArt extends StatelessWidget {
  final Track track;
  final double size;
  final double radius;
  const TrackArt(this.track, {super.key, this.size = 48, this.radius = 10});

  @override
  Widget build(BuildContext context) => ArtImage(file: store.artFor(track), size: size, radius: radius);
}

/// One row in a song list. Tapping plays [list] starting at this song.
class TrackTile extends StatelessWidget {
  final Track track;
  final List<Track> list;
  final int index;
  final bool showArt;

  const TrackTile({super.key, required this.track, required this.list, required this.index, this.showArt = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([playerService, store]),
      builder: (context, _) {
        final isCurrent = playerService.current?.id == track.id;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: showArt ? TrackArt(track) : null,
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: isCurrent ? kAccent : kText, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            track.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: kMuted, fontSize: 13),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCurrent)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: EqBars(color: kAccent, height: 14, bars: 3, playing: playerService.player.playing),
                ),
              if (store.isLiked(track.id))
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.favorite, color: kPink, size: 16),
                ),
              if (store.momentsOf(track.id).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Icon(Icons.push_pin_rounded, color: kPink.withValues(alpha: 0.8), size: 15),
                ),
              IconButton(
                tooltip: 'More',
                icon: Icon(Icons.more_vert, color: kMuted),
                onPressed: () => showTrackMenu(context, track),
              ),
            ],
          ),
          onTap: () => playerService.playTracks(list, start: index),
          onLongPress: () => showTrackMenu(context, track),
        );
      },
    );
  }
}

void showTrackMenu(BuildContext context, Track t) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: TrackArt(t),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(store.isLiked(t.id) ? Icons.favorite : Icons.favorite_border, color: kPink),
            title: Text(store.isLiked(t.id) ? 'Remove from Liked Songs' : 'Add to Liked Songs'),
            onTap: () {
              store.toggleLike(t.id);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_play),
            title: const Text('Play next'),
            onTap: () {
              playerService.playNext(t);
              Navigator.pop(ctx);
              _toast(context, 'Playing next');
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('Add to queue'),
            onTap: () {
              playerService.addToQueue(t);
              Navigator.pop(ctx);
              _toast(context, 'Added to queue');
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Details'),
            onTap: () {
              Navigator.pop(ctx);
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(t.title),
                  content: Text(
                    'Artist: ${t.artist.isEmpty ? '—' : t.artist}\n'
                    'Album: ${t.album.isEmpty ? '—' : t.album}\n'
                    'Length: ${formatDuration(t.length)}\n'
                    'Size: ${formatBytes(t.size)}\n'
                    'Played: ${store.playCounts[t.id] ?? 0} times\n'
                    'Folder: ${t.folder}',
                  ),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 1)));
}

/// Glass dock above the bottom navigation showing the current song.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([playerService, store]),
      builder: (context, _) {
        final t = playerService.current;
        if (t == null) return const SizedBox.shrink();
        final p = playerService.player;
        return GestureDetector(
          onTap: () => openNowPlaying(context),
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -200) openNowPlaying(context);
          },
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) playerService.next();
            if (v > 300) playerService.previous();
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            decoration: BoxDecoration(
              color: pal.dark ? const Color(0xF0181524) : const Color(0xF5FFFFFF),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kLine),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: pal.dark ? 0.35 : 0.10), blurRadius: 30, offset: const Offset(0, 12)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                  child: Row(
                    children: [
                      Hero(tag: 'art', child: TrackArt(t, size: 44, radius: 12)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: kText)),
                            Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                      if (p.playing) Padding(padding: const EdgeInsets.only(right: 4), child: EqBars(color: kAccent, height: 14, bars: 3)),
                      IconButton(
                        tooltip: store.isLiked(t.id) ? 'Remove from Liked Songs' : 'Add to Liked Songs',
                        icon: Icon(store.isLiked(t.id) ? Icons.favorite : Icons.favorite_border, color: store.isLiked(t.id) ? kPink : kMuted),
                        onPressed: () => store.toggleLike(t.id),
                      ),
                      Pressable(
                        onTap: playerService.togglePlay,
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(color: kText, shape: BoxShape.circle),
                          child: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: kBg, size: 26, semanticLabel: p.playing ? 'Pause' : 'Play'),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: StreamBuilder<Duration>(
                    stream: p.positionStream,
                    builder: (context, snap) {
                      final total = p.duration?.inMilliseconds ?? 0;
                      final pos = snap.data?.inMilliseconds ?? 0;
                      final f = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: f,
                          child: Container(height: 2.5, decoration: const BoxDecoration(gradient: kBrandGradient)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

void openNowPlaying(BuildContext context) {
  Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 480),
    reverseTransitionDuration: const Duration(milliseconds: 360),
    pageBuilder: (_, __, ___) => const NowPlayingScreen(),
    transitionsBuilder: (_, anim, __, child) {
      final c = CurvedAnimation(parent: anim, curve: const Cubic(0.2, 0.8, 0.2, 1), reverseCurve: Curves.easeInCubic);
      return FadeTransition(
        opacity: c,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(c),
          child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(c), child: child),
        ),
      );
    },
  ));
}
