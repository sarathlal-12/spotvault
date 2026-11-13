import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'aurora.dart';
import 'common.dart';

/// Song list for a playlist, Liked Songs, All Songs, etc.
class TrackListScreen extends StatefulWidget {
  final String title;
  final List<Track> Function() source;
  final File? cover;
  final IconData icon;
  final bool allowPcOrder;

  const TrackListScreen({
    super.key,
    required this.title,
    required this.source,
    this.cover,
    this.icon = Icons.queue_music,
    this.allowPcOrder = true,
  });

  @override
  State<TrackListScreen> createState() => _TrackListScreenState();
}

class _TrackListScreenState extends State<TrackListScreen> {
  late TrackSort sort = widget.allowPcOrder ? TrackSort.pcOrder : TrackSort.title;
  String filter = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          var tracks = LibraryStore.sortTracks(widget.source(), sort);
          if (filter.isNotEmpty) {
            final f = filter.toLowerCase();
            tracks = tracks.where((t) => t.title.toLowerCase().contains(f) || t.artist.toLowerCase().contains(f)).toList();
          }
          final total = tracks.fold(Duration.zero, (s, t) => s + t.length);

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 300,
                backgroundColor: kBg,
                actions: [
                  PopupMenuButton<TrackSort>(
                    icon: const Icon(Icons.sort),
                    initialValue: sort,
                    onSelected: (s) => setState(() => sort = s),
                    itemBuilder: (_) => [
                      if (widget.allowPcOrder) const PopupMenuItem(value: TrackSort.pcOrder, child: Text('PC order')),
                      const PopupMenuItem(value: TrackSort.title, child: Text('Title')),
                      const PopupMenuItem(value: TrackSort.artist, child: Text('Artist')),
                      const PopupMenuItem(value: TrackSort.recentlyAdded, child: Text('Recently added')),
                    ],
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14, end: 56),
                  title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  background: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [kViolet.withValues(alpha: pal.dark ? 0.45 : 0.25), kBg],
                      ),
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.only(top: 40, bottom: 50),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: LayoutBuilder(
                        builder: (_, c) => Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(26),
                            boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.45), blurRadius: 40, offset: const Offset(0, 16))],
                          ),
                          child: ArtImage(file: widget.cover, size: c.maxWidth, radius: 26, fallback: widget.icon),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${tracks.length} songs · ${formatDuration(total)}',
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Shuffle',
                        iconSize: 28,
                        icon: Icon(Icons.shuffle, color: kAccent),
                        onPressed: tracks.isEmpty ? null : () => playerService.playTracks(tracks, start: -1, shuffle: true),
                      ),
                      const SizedBox(width: 4),
                      Pressable(
                        onTap: () {
                          if (tracks.isNotEmpty) playerService.playTracks(tracks, shuffle: false);
                        },
                        child: Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            gradient: kBrandGradient,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.5), blurRadius: 22, offset: const Offset(0, 8))],
                          ),
                          child: const Icon(Icons.play_arrow_rounded, size: 34, color: Colors.white, semanticLabel: 'Play all'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => filter = v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find in ${widget.title}',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      filled: true,

                    ),
                  ),
                ),
              ),
              if (tracks.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No songs here yet', style: TextStyle(color: kMuted))),
                )
              else
                SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (_, i) => TrackTile(track: tracks[i], list: tracks, index: i),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 90)),
            ],
          );
        },
      ),
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
    );
  }
}
