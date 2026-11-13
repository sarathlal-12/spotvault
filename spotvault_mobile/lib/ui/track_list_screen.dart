import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
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
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF2E2560), kBg],
                      ),
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.only(top: 40, bottom: 50),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: LayoutBuilder(
                        builder: (_, c) => ArtImage(file: widget.cover, size: c.maxWidth, radius: 4, fallback: widget.icon),
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
                          style: const TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Shuffle',
                        iconSize: 28,
                        icon: const Icon(Icons.shuffle, color: kAccent),
                        onPressed: tracks.isEmpty ? null : () => playerService.playTracks(tracks, start: -1, shuffle: true),
                      ),
                      const SizedBox(width: 4),
                      FloatingActionButton(
                        heroTag: null,
                        backgroundColor: kAccent,
                        foregroundColor: Colors.white,
                        shape: const CircleBorder(),
                        onPressed: tracks.isEmpty ? null : () => playerService.playTracks(tracks, shuffle: false),
                        child: const Icon(Icons.play_arrow, size: 32),
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
                      fillColor: kCard,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ),
              if (tracks.isEmpty)
                const SliverFillRemaining(
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
