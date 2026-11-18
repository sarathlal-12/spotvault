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
  late TrackSort sort = _savedSort() ?? (widget.allowPcOrder ? TrackSort.pcOrder : TrackSort.title);

  static const _sortKeys = {
    TrackSort.pcOrder: 'pc',
    TrackSort.title: 'title',
    TrackSort.artist: 'artist',
    TrackSort.recentlyAdded: 'recent'
  };

  /// Each playlist remembers how you sorted it.
  TrackSort? _savedSort() {
    final key = widget.playlistFolder == null ? null : store.playlistSort[widget.playlistFolder];
    for (final e in _sortKeys.entries) {
      if (e.value == key) return e.key;
    }
    return null;
  }

  void _setSort(TrackSort s) {
    setState(() => sort = s);
    final f = widget.playlistFolder;
    if (f != null) {
      store.playlistSort[f] = _sortKeys[s]!;
      store.changed();
    }
  }

  String filter = '';
  bool reordering = false;

  PlaylistInfo? get playlist => widget.playlistFolder == null ? null : store.playlistByFolder(widget.playlistFolder!);

  /// Minimal look (2.0 design): round buttons, the cover beside the title, Play and Shuffle.
  Widget _minimalHeader(BuildContext context, PlaylistInfo? pl, String title, File? cover, List<Track> tracks, Duration total) {
    Widget round(IconData icon, String label, VoidCallback onTap) => Tooltip(
          message: label,
          child: Semantics(
            button: true,
            label: label,
            child: Pressable(
              onTap: onTap,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kLine)),
                child: Icon(icon, size: 20, color: kText),
              ),
            ),
          ),
        );
    return SliverToBoxAdapter(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              round(Icons.arrow_back_rounded, 'Back', () => Navigator.maybePop(context)),
              const Spacer(),
              if (reordering)
                TextButton(onPressed: () => setState(() => reordering = false), child: const Text('Done'))
              else if (pl != null)
                round(
                    Icons.more_horiz_rounded,
                    'Playlist options',
                    () => showPlaylistMenu(context, pl,
                        onReorder: () => setState(() {
                              reordering = true;
                              sort = TrackSort.pcOrder;
                              filter = '';
                            }))),
            ]),
            const SizedBox(height: 18),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  // Cloud's wavy cover has no square shadow behind it.
                  boxShadow: isCloud
                      ? null
                      : [BoxShadow(color: Colors.black.withValues(alpha: pal.dark ? 0.4 : 0.16), blurRadius: 30, offset: const Offset(0, 14))],
                ),
                child: ArtImage(file: cover, size: 132, radius: 26, fallback: widget.icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  splitTitle(reordering ? 'Drag to reorder' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.1, color: kText)),
                  const SizedBox(height: 4),
                  Text('${tracks.length} songs · ${formatDuration(total)}', style: TextStyle(color: kMuted, fontSize: 13)),
                  const SizedBox(height: 12),
                  Row(children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: kText,
                        foregroundColor: kBg,
                        shape: const StadiumBorder(),
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      onPressed: tracks.isEmpty ? null : () => playerService.playTracks(tracks, shuffle: false),
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: const Text('Play', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 8),
                    round(Icons.shuffle_rounded, 'Shuffle play', () {
                      if (tracks.isNotEmpty) playerService.playTracks(tracks, start: -1, shuffle: true);
                    }),
                  ]),
                ]),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

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

          final minimal = isMinimal;
          return CustomScrollView(
            slivers: [
              if (minimal) _minimalHeader(context, pl, title, cover, tracks, total),
              if (!minimal)
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
                        onSelected: _setSort,
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
              if (!minimal)
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
                            child: Icon(Icons.play_arrow_rounded, size: 34, color: kOnInk, semanticLabel: 'Play all'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!reordering && pl != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Material(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          searchTarget.value = pl.folder;
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          currentTab.value = 1;
                        },
                        child: Container(
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
                          child: Row(children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(color: isCloud ? kInk : const Color(0xFFE0403B), shape: BoxShape.circle),
                              child: Icon(Icons.add_rounded, color: kOnInk, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text('Add songs from the web', style: TextStyle(color: kText, fontWeight: FontWeight.w600))),
                            Icon(Icons.search_rounded, color: kMuted, size: 18),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              if (minimal && !reordering)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        Text('Sort', style: TextStyle(color: kMuted, fontSize: 12)),
                        const SizedBox(width: 8),
                        for (final (s, label) in [
                          if (widget.allowPcOrder) (TrackSort.pcOrder, 'My order'),
                          (TrackSort.recentlyAdded, 'Recently added'),
                          (TrackSort.title, 'A–Z'),
                          (TrackSort.artist, 'Artist'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(label),
                              selected: sort == s,
                              showCheckmark: false,
                              onSelected: (_) => _setSort(s),
                              selectedColor: kText,
                              labelStyle: TextStyle(color: sort == s ? kBg : kText, fontWeight: FontWeight.w600, fontSize: 12),
                              shape: StadiumBorder(side: BorderSide(color: sort == s ? kText : kLine)),
                            ),
                          ),
                      ]),
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
