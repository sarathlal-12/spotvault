import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'common.dart';

/// Song menu: long-press or ⋮ on any song. [playlist] is the playlist the
/// song is shown in, if any (enables "Remove from this playlist").
void showSongMenu(BuildContext context, Track t, {PlaylistInfo? playlist}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: TrackArt(t),
              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            _item(ctx, store.isLiked(t.id) ? Icons.favorite : Icons.favorite_border,
                store.isLiked(t.id) ? 'Remove from Liked Songs' : 'Add to Liked Songs', () => store.toggleLike(t.id),
                color: kPink),
            _item(ctx, Icons.playlist_play_rounded, 'Play next', () {
              playerService.playNext(t);
              toast(context, 'Playing next');
            }),
            _item(ctx, Icons.queue_music_rounded, 'Add to queue', () {
              playerService.addToQueue(t);
              toast(context, 'Added to queue');
            }),
            _item(ctx, Icons.playlist_add_rounded, 'Add to playlist', () => showAddToPlaylist(context, [t])),
            if (playlist != null)
              _item(ctx, Icons.playlist_remove_rounded, 'Remove from this playlist', () {
                store.removeFromPlaylist(playlist, t.id);
                toast(context, 'Removed from ${playlist.name}');
              }),
            if (shareSongs != null) _item(ctx, Icons.ios_share_rounded, 'Share to a nearby phone', () => shareSongs!(context, [t], null)),
            _item(ctx, Icons.delete_outline_rounded, 'Delete…', () => confirmDeleteSongs(context, [t]), color: pal.danger),
            _item(ctx, Icons.info_outline_rounded, 'Details', () => _details(context, t)),
          ],
        ),
      ),
    ),
  );
}

/// Set by the share feature so menus can offer "Share to a nearby phone".
Future<void> Function(BuildContext context, List<Track> tracks, PlaylistInfo? playlist)? shareSongs;

Widget _item(BuildContext ctx, IconData icon, String label, VoidCallback onTap, {Color? color}) => ListTile(
      leading: Icon(icon, color: color ?? kText),
      title: Text(label, style: TextStyle(color: color == pal.danger ? color : null)),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
}

void _details(BuildContext context, Track t) {
  showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(t.title),
      content: Text(
        'Artist: ${t.artist.isEmpty ? '—' : t.artist}\n'
        'Album: ${t.album.isEmpty ? '—' : t.album}\n'
        'Length: ${formatDuration(t.length)}\n'
        'Size: ${formatBytes(t.size)}\n'
        'Played: ${store.playCounts[t.id] ?? 0} times\n'
        'Saved ${t.phoneOnly ? 'on this phone' : 'from your PC'} · ${t.folder}',
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}

// ------------------------------------------------------------------ delete
Future<void> confirmDeleteSongs(BuildContext context, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final fromPc = tracks.where((t) => !t.phoneOnly).length;
  final what = tracks.length == 1 ? '"${tracks.first.title}"' : '${tracks.length} songs';
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete $what?'),
      content: Text(fromPc == 0
          ? 'This removes the song from your phone.'
          : '"Remove from phone" keeps it on your PC, and it won\'t come back on the next sync.\n\n'
              '"Delete from phone and PC" also deletes the PC\'s copy at your next sync.'),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'phone'),
          child: Text(fromPc == 0 ? 'Delete' : 'Remove from phone', style: TextStyle(color: pal.danger)),
        ),
        if (fromPc > 0)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kViolet, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, 'pc'),
            child: const Text('Delete from phone and PC'),
          ),
      ],
    ),
  );
  if (choice == null) return;
  for (final t in tracks) {
    if (playerService.current?.id == t.id) await playerService.player.stop();
  }
  await store.removeSongs(tracks.map((t) => t.id), alsoPc: choice == 'pc');
  if (context.mounted) {
    toast(context, choice == 'pc' ? 'Deleted. Your PC deletes its copy at the next sync.' : 'Deleted from this phone');
  }
}

Future<bool> confirmDeletePlaylist(BuildContext context, PlaylistInfo p) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete "${p.name}"?'),
      content: Text(p.phoneOnly
          ? 'The playlist and the songs only it has are removed from this phone.'
          : '"Remove from phone" keeps it on your PC, and it won\'t come back on the next sync.\n\n'
              '"Delete from phone and PC" also removes it from SpotVault on your PC and moves its folder '
              'to the Recycle Bin at your next sync.'),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'phone'),
          child: Text(p.phoneOnly ? 'Delete' : 'Remove from phone', style: TextStyle(color: pal.danger)),
        ),
        if (!p.phoneOnly)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kViolet, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, 'pc'),
            child: const Text('Delete from phone and PC'),
          ),
      ],
    ),
  );
  if (choice == null) return false;
  await store.deletePlaylist(p, alsoPc: choice == 'pc');
  if (context.mounted) toast(context, 'Deleted "${p.name}"');
  return true;
}

// ------------------------------------------------------------------ playlists
/// Asks for a playlist name. Returns null when cancelled.
Future<String?> askPlaylistName(BuildContext context,
    {String title = 'New playlist', String initial = '', String action = 'Create'}) async {
  final ctrl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(action)),
      ],
    ),
  );
  ctrl.dispose();
  final clean = (name ?? '').trim();
  return clean.isEmpty ? null : clean;
}

Future<PlaylistInfo?> createPlaylistFlow(BuildContext context) async {
  final name = await askPlaylistName(context);
  if (name == null) return null;
  final p = store.createPlaylist(name);
  if (context.mounted) toast(context, 'Made "${p.name}"');
  return p;
}

/// "Add to playlist": pick one (or make a new one).
Future<void> showAddToPlaylist(BuildContext context, List<Track> tracks) async {
  final pick = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text('Add to playlist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: _plusBox(),
              title: const Text('New playlist'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in store.sortedPlaylists)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                      leading: ArtImage(file: store.coverFor(p), size: 48, fallback: Icons.queue_music),
                      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${p.trackIds.length} songs', style: TextStyle(color: kMuted, fontSize: 12)),
                      onTap: () => Navigator.pop(ctx, p),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (pick == null || !context.mounted) return;
  final PlaylistInfo? p = pick == 'new' ? await createPlaylistFlow(context) : pick as PlaylistInfo;
  if (p == null) return;
  var added = 0;
  for (final t in tracks) {
    if (store.addToPlaylist(p, t)) added++;
  }
  if (context.mounted) {
    toast(context, added == 0 ? 'Already in ${p.name}' : 'Added to ${p.name}');
  }
}

Widget _plusBox() => Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
      child: Icon(Icons.add_rounded, color: kAccent),
    );

/// Playlist menu: long-press a playlist, or ⋮ on its page.
/// [onReorder] starts reorder mode when shown from the playlist's page.
void showPlaylistMenu(BuildContext context, PlaylistInfo p, {VoidCallback? onReorder, VoidCallback? onDeleted}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: ArtImage(file: store.coverFor(p), size: 48, fallback: Icons.queue_music),
            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${p.trackIds.length} songs${p.phoneOnly ? ' · on this phone' : ''}', style: TextStyle(color: kMuted)),
          ),
          const Divider(height: 1),
          _item(ctx, p.pinned ? Icons.push_pin : Icons.push_pin_outlined, p.pinned ? 'Unpin' : 'Pin to top',
              () => store.setPinned(p, !p.pinned)),
          _item(ctx, Icons.edit_rounded, 'Rename', () async {
            final name = await askPlaylistName(context, title: 'Rename playlist', initial: p.name, action: 'Save');
            if (name != null) store.renamePlaylist(p, name);
          }),
          _item(ctx, Icons.image_outlined, 'Change cover', () => changeCover(context, p)),
          if (onReorder != null) _item(ctx, Icons.swap_vert_rounded, 'Reorder songs', onReorder),
          if (shareSongs != null)
            _item(ctx, Icons.ios_share_rounded, 'Share to a nearby phone', () => shareSongs!(context, store.tracksOf(p), p)),
          _item(ctx, Icons.delete_outline_rounded, 'Delete playlist…', () async {
            if (await confirmDeletePlaylist(context, p)) onDeleted?.call();
          }, color: pal.danger),
        ],
      ),
    ),
  );
}

/// Pick a cover: a photo, one of the playlist's song covers, or the default.
Future<void> changeCover(BuildContext context, PlaylistInfo p) async {
  final arts = [
    for (final t in store.tracksOf(p))
      if (t.hasArt) store.artFile(t),
  ].take(24).toList();
  final pick = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Playlist cover', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            if (p.customCover)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt_rounded),
                title: const Text('Use the original cover'),
                onTap: () => Navigator.pop(ctx, 'reset'),
              ),
            if (arts.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Or use a song\'s cover', style: TextStyle(color: kMuted)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.4),
                child: GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final f in arts)
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx, f),
                        child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(f, fit: BoxFit.cover)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  if (pick == null) return;
  try {
    if (pick == 'reset') {
      await store.setCustomCover(p, null);
    } else if (pick == 'photo') {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1000, maxHeight: 1000, imageQuality: 88);
      if (x == null) return;
      await store.setCustomCover(p, await x.readAsBytes());
    } else if (pick is File) {
      await store.setCustomCover(p, await pick.readAsBytes());
    }
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't set the cover: $e");
  }
}
