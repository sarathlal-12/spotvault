import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'aurora.dart';
import 'common.dart';
import 'menus.dart';

/// Song list for a playlist, Liked Songs, All Songs, etc.
class TrackListScreen extends StatefulWidget {
  final String title;
  final List<Track> Function() source;
  final File? cover;
  final IconData icon;
  final bool allowPcOrder;

  /// Set when this page shows a playlist: enables its menu and reordering.
  final String? playlistFolder;

  const TrackListScreen({
    super.key,
    required this.title,
    required this.source,
    this.cover,
    this.icon = Icons.queue_music,
    this.allowPcOrder = true,
    this.playlistFolder,
  });

  @override
  State<TrackListScreen> createState() => _TrackListScreenState();
}

class _TrackListScreenState extends State<TrackListScreen> {
  late TrackSort sort = widget.allowPcOrder ? TrackSort.pcOrder : TrackSort.title;
  String filter = '';
  bool reordering = false;

  PlaylistInfo? get playlist => widget.playlistFolder == null ? null : store.playlistByFolder(widget.playlistFolder!);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final pl = playlist;
          if (widget.playlistFolder != null && pl == null) {
            // The playlist was deleted.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && Navigator.canPop(context)) Navigator.pop(context);
            });
            return const SizedBox.shrink();
          }
          final title = pl?.name ?? widget.title;
          final cover = pl != null ? store.coverFor(pl) : widget.cover;
          var tracks = LibraryStore.sortTracks(widget.source(), reordering ? TrackSort.pcOrder : sort);
          if (filter.isNotEmpty && !reordering) {
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
                  if (reordering)
                    TextButton(onPressed: () => setState(() => reordering = false), child: const Text('Done'))
                  else ...[
                    PopupMenuButton<TrackSort>(
                      icon: const Icon(Icons.sort),
                      initialValue: sort,
                      onSelected: (s) => setState(() => sort = s),
                      itemBuilder: (_) => [
                        if (widget.allowPcOrder)
                          PopupMenuItem(
                              value: TrackSort.pcOrder,
                              child: Text(pl != null && (pl.customOrder || pl.phoneOnly) ? 'Playlist order' : 'PC order')),
                        const PopupMenuItem(value: TrackSort.title, child: Text('Title')),
                        const PopupMenuItem(value: TrackSort.artist, child: Text('Artist')),
                        const PopupMenuItem(value: TrackSort.recentlyAdded, child: Text('Recently added')),
                      ],
                    ),
                    if (pl != null)
                      IconButton(
                        tooltip: 'Playlist options',
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => showPlaylistMenu(context, pl,
                            onReorder: () => setState(() {
                                  reordering = true;
                                  sort = TrackSort.pcOrder;
                                  filter = '';
                                })),
                      ),
                  ],
                ],
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14, end: 56),
                  title: Text(reordering ? 'Drag to reorder' : title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
                          child: ArtImage(file: cover, size: c.maxWidth, radius: 26, fallback: widget.icon),
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
              if (!reordering)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      onChanged: (v) => setState(() => filter = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Find in $title',
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
              else if (reordering && pl != null)
                SliverReorderableList(
                  itemCount: tracks.length,
                  onReorderItem: (from, to) {
                    final ids = tracks.map((t) => t.id).toList();
                    ids.insert(to, ids.removeAt(from));
                    store.setPlaylistOrder(pl, ids);
                  },
                  itemBuilder: (_, i) => Material(
                    key: ValueKey(tracks[i].id),
                    color: Colors.transparent,
                    child: ListTile(
                      leading: TrackArt(tracks[i]),
                      title: Text(tracks[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(tracks[i].subtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 13)),
                      trailing: ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle_rounded, color: kMuted)),
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (_, i) => TrackTile(track: tracks[i], list: tracks, index: i, playlist: pl),
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
