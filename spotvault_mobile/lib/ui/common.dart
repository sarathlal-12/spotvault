import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
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
      color: kCard,
      alignment: Alignment.center,
      child: Icon(fallback, color: kMuted, size: size * 0.45),
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
  const TrackArt(this.track, {super.key, this.size = 48, this.radius = 4});

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
            style: TextStyle(color: isCurrent ? kAccent : Colors.white, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            track.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kMuted, fontSize: 13),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCurrent && playerService.player.playing)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.graphic_eq, color: kAccent, size: 18),
                ),
              if (store.isLiked(track.id))
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.favorite, color: kAccent, size: 16),
                ),
              IconButton(
                icon: const Icon(Icons.more_vert, color: kMuted),
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
    backgroundColor: kSurface,
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
            leading: Icon(store.isLiked(t.id) ? Icons.favorite : Icons.favorite_border, color: kAccent),
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

/// Bar above the bottom navigation showing the current song.
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
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                  child: Row(
                    children: [
                      Hero(tag: 'art', child: TrackArt(t, size: 42)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(store.isLiked(t.id) ? Icons.favorite : Icons.favorite_border,
                            color: store.isLiked(t.id) ? kAccent : Colors.white),
                        onPressed: () => store.toggleLike(t.id),
                      ),
                      IconButton(
                        icon: Icon(p.playing ? Icons.pause : Icons.play_arrow, size: 30),
                        onPressed: playerService.togglePlay,
                      ),
                    ],
                  ),
                ),
                StreamBuilder<Duration>(
                  stream: p.positionStream,
                  builder: (context, snap) {
                    final total = p.duration?.inMilliseconds ?? 0;
                    final pos = snap.data?.inMilliseconds ?? 0;
                    return LinearProgressIndicator(
                      value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0,
                      minHeight: 2,
                      backgroundColor: Colors.white12,
                      color: Colors.white,
                    );
                  },
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
    pageBuilder: (_, __, ___) => const NowPlayingScreen(),
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}
