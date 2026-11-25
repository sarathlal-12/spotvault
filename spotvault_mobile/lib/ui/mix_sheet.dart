import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'common.dart';
import 'menus.dart';

/// Mix: pick some playlists and play all their songs shuffled together, or
/// keep the mix as a new playlist.
Future<void> showMixSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _MixSheet(),
    );

class _MixSheet extends StatefulWidget {
  const _MixSheet();

  @override
  State<_MixSheet> createState() => _MixSheetState();
}

class _MixSheetState extends State<_MixSheet> {
  final Set<String> _picked = {};

  List<Track> get _songs {
    final seen = <String>{};
    return [
      for (final p in store.sortedPlaylists)
        if (_picked.contains(p.folder))
          for (final t in store.tracksOf(p))
            if (seen.add(t.id)) t,
    ];
  }

  Future<void> _play() async {
    final songs = _songs;
    if (songs.isEmpty) return;
    Navigator.pop(context);
    await playerService.playTracks(List.of(songs)..shuffle(), shuffle: true);
  }

  Future<void> _save() async {
    final songs = _songs;
    if (songs.isEmpty) return;
    final name = await askPlaylistName(context, initial: 'Mix');
    if (name == null) return;
    final p = store.createPlaylist(name);
    for (final t in songs) {
      store.addToPlaylist(p, t);
    }
    if (!mounted) return;
    Navigator.pop(context);
    toast(context, 'Saved "${p.name}" with ${songs.length} songs');
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final lists = store.sortedPlaylists.where((l) => l.trackIds.isNotEmpty).toList();
    final n = _songs.length;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Mix playlists', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Pick the playlists to mix. Their songs play in random order.', style: TextStyle(color: p.muted, fontSize: 13)),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final l in lists)
                CheckboxListTile(
                  value: _picked.contains(l.folder),
                  onChanged: (v) => setState(() => v == true ? _picked.add(l.folder) : _picked.remove(l.folder)),
                  secondary: ArtImage(file: store.coverFor(l), size: 44, radius: 10, fallback: Icons.queue_music_rounded),
                  title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${l.trackIds.length} songs', style: TextStyle(color: p.muted, fontSize: 12)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: n == 0 ? null : _save,
                  icon: const Icon(Icons.playlist_add_rounded, size: 18),
                  label: const Text('Save as playlist'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: n == 0 ? null : _play,
                  icon: const Icon(Icons.shuffle_rounded, size: 18),
                  label: Text(n == 0 ? 'Play mix' : 'Play $n songs'),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
