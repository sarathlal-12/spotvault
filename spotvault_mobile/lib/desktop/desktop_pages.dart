import 'dart:io' show File;
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../song_list.dart';
import '../ui/common.dart' show ArtImage, TrackArt;
import '../ui/lab_screen.dart';
import '../ui/menus.dart' show showSongMenu;
import '../ui/nearby_ui.dart' show JamScreen;
import '../ui/qr.dart' show pcLinkFor;
import 'desktop_shell.dart';
import 'engine_client.dart';

Widget pageFor(DPage page) => switch (page) {
      DPage.home => const HomePage(),
      DPage.songs => const SongsPage(),
      DPage.playlist => PlaylistPage(folder: dPlaylist.value),
      DPage.search => SearchPage(initial: dSearchQuery),
      DPage.sync => const SyncPage(),
      DPage.jam => const _Nested(child: JamScreen()),
      DPage.studio => const _Nested(child: LabScreen()),
      DPage.settings => const SettingsPage(),
    };

String dSearchQuery = '';
String? dSearchFolder;

void openSearch(String q, {String? folder}) {
  dSearchQuery = q;
  dSearchFolder = folder;
  dPage.value = DPage.search;
}

/// Phone screens shown inside the window (their own navigator, so "back" stays inside).
class _Nested extends StatelessWidget {
  final Widget child;
  const _Nested({required this.child});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(0),
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, __, ___) => Material(color: Colors.transparent, child: child))),
      );
}

void dToast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), width: 460));
}

TextStyle _h1() => TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.6, color: pal.text);
TextStyle _h2() => TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pal.text);
TextStyle _muted([double size = 14]) => TextStyle(fontSize: size, color: pal.muted);

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(20)});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: pal.text.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: pal.line),
        ),
        child: child,
      );
}

ButtonStyle _primary() => FilledButton.styleFrom(
      backgroundColor: isMinimal ? pal.text : kViolet,
      foregroundColor: isMinimal ? pal.bg : Colors.white,
      minimumSize: const Size(0, 46),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    );

ButtonStyle _outline() => OutlinedButton.styleFrom(
      foregroundColor: pal.text,
      minimumSize: const Size(0, 42),
      side: BorderSide(color: pal.line),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    );

Widget _pill(String text, {VoidCallback? onTap, IconData? icon}) => OutlinedButton.icon(
      style: _outline(),
      onPressed: onTap,
      icon: icon == null ? const SizedBox(width: 0) : Icon(icon, size: 16),
      label: Text(text),
    );

/// Song list import: paste the list (or open a .txt), see what's in it, download it all.
Future<void> importSongListDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  String? err;
  var busy = false;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final lists = parseSongList(ctrl.text);
      final songs = lists.values.fold<int>(0, (n, l) => n + l.length);
      Future<void> go() async {
        setState(() {
          busy = true;
          err = null;
        });
        final e = await engine.importLists(lists);
        if (e != null) {
          setState(() {
            busy = false;
            err = e;
          });
          return;
        }
        if (context.mounted) Navigator.pop(context);
        dPage.value = DPage.sync;
      }

      return AlertDialog(
        title: const Text('Import a song list'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Paste the list from your phone (Studio, Song list, Copy), or open a .txt file. Each "## name" becomes a playlist; songs you already have are skipped.', style: _muted(13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              minLines: 8,
              maxLines: 12,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: '## Drive mix\nMidnight Drive - Night Cassette', errorText: err, errorMaxLines: 3, border: const OutlineInputBorder()),
              style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(songs == 0 ? 'No songs yet.' : '$songs songs in ${lists.length} playlist${lists.length == 1 ? '' : 's'}: ${lists.keys.take(4).join(', ')}${lists.length > 4 ? '…' : ''}', style: _muted(12))),
              TextButton.icon(
                onPressed: () async {
                  final f = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'Text', extensions: ['txt'])]);
                  if (f == null) return;
                  ctrl.text = await f.readAsString();
                  setState(() {});
                },
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('Open .txt'),
              ),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(style: _primary(), onPressed: busy || songs == 0 ? null : go, child: Text(busy ? 'Starting…' : 'Download $songs songs')),
        ],
      );
    }),
  );
}

/// "Add a playlist": paste a Spotify, YouTube or SoundCloud link.
Future<void> addPlaylistDialog(BuildContext context, {bool syncNow = true}) async {
  final ctrl = TextEditingController();
  String? err;
  var busy = false;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> go({bool online = false}) async {
          setState(() {
            busy = true;
            err = null;
          });
          final before = engine.playlists.map((p) => p['folder']).toSet();
          final e = await engine.addPlaylist(ctrl.text.trim());
          if (e != null) {
            setState(() {
              busy = false;
              err = e;
            });
            return;
          }
          await engine.refresh();
          final added = engine.playlists.map((p) => '${p['folder']}').where((f) => !before.contains(f)).toList();
          if (context.mounted) Navigator.pop(context);
          if (online && added.isNotEmpty) {
            // Play online: nothing downloads; the playlist page lists the songs to stream.
            openPlaylist(added.first);
            return;
          }
          if (syncNow && added.isNotEmpty) await engine.syncFolders(added);
          dPage.value = DPage.sync;
        }

        return AlertDialog(
          title: const Text('Add a playlist'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Paste a Spotify, YouTube, YouTube Music or SoundCloud playlist link. Download it to this PC, or play it online for now and download later.', style: _muted(13)),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                autofocus: true,
                onSubmitted: (_) => busy ? null : go(),
                decoration: InputDecoration(hintText: 'https://open.spotify.com/playlist/…', errorText: err, errorMaxLines: 3, prefixIcon: const Icon(Icons.link_rounded)),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            OutlinedButton.icon(style: _outline(), onPressed: busy ? null : () => go(online: true), icon: const Icon(Icons.wifi_rounded, size: 16), label: const Text('Play online')),
            FilledButton.icon(style: _primary(), onPressed: busy ? null : go, icon: const Icon(Icons.download_rounded, size: 16), label: Text(busy ? 'Adding…' : 'Download')),
          ],
        );
      },
    ),
  );
}

// ============================================================ Home
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, engine]),
      builder: (context, _) {
        final p = pal;
        final lists = store.sortedPlaylists;
        final recent = store.recentTracks.take(8).toList();
        final name = store.userName.trim();
        final last = engine.lastReport?['finished'] as num?;
        return ListView(padding: const EdgeInsets.fromLTRB(30, 28, 30, 30), children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${greeting()}${name.isEmpty ? '' : ', $name'}', style: _h1()),
                const SizedBox(height: 4),
                Text(
                    '${store.tracks.length} songs in your vault'
                    '${last == null ? '' : ' · last sync ${_ago(DateTime.fromMillisecondsSinceEpoch((last * 1000).round()))}'}',
                    style: _muted()),
              ]),
            ),
            SizedBox(
              width: 340,
              child: TextField(
                onSubmitted: (q) => q.trim().isEmpty ? null : openSearch(q.trim()),
                decoration: InputDecoration(
                  hintText: 'Search the web for songs…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(99), borderSide: BorderSide(color: p.line)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(99), borderSide: BorderSide(color: p.line)),
                ),
              ),
            ),
          ]),
          if (engine.syncing) ...[
            const SizedBox(height: 18),
            _SyncStrip(),
          ],
          const SizedBox(height: 26),
          Row(children: [
            Expanded(child: Text('Jump back in', style: _h2())),
            TextButton(onPressed: () => addPlaylistDialog(context), child: const Text('Add playlist')),
          ]),
          const SizedBox(height: 12),
          if (lists.isEmpty)
            _Card(
              child: Row(children: [
                Expanded(child: Text('No playlists yet. Paste a playlist link and SpotVault saves every song.', style: _muted())),
                FilledButton(style: _primary(), onPressed: () => addPlaylistDialog(context), child: const Text('Add a playlist')),
              ]),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 190, mainAxisSpacing: 18, crossAxisSpacing: 18, childAspectRatio: 0.72),
              itemCount: math.min(lists.length, 12),
              itemBuilder: (context, i) => _PlaylistCard(lists[i]),
            ),
          const SizedBox(height: 28),
          Text('Recently played', style: _h2()),
          const SizedBox(height: 8),
          if (recent.isEmpty) Text('Songs you play show up here.', style: _muted(13)),
          for (var i = 0; i < recent.length; i++) TrackRow(recent[i], list: recent, index: i),
        ]);
      },
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

class _PlaylistCard extends StatefulWidget {
  final PlaylistInfo pl;
  const _PlaylistCard(this.pl);

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final pl = widget.pl;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: () => openPlaylist(pl.folder),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 1,
            child: AnimatedScale(
              scale: hover ? 1.03 : 1,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Stack(children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: hover ? 0.32 : 0.2), blurRadius: hover ? 30 : 18, offset: const Offset(0, 12)),
                    ]),
                    child: LayoutBuilder(builder: (c, b) => ArtImage(file: store.coverFor(pl), size: b.maxWidth, radius: 18, fallback: Icons.queue_music_rounded)),
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: AnimatedOpacity(
                    opacity: hover ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Material(
                      color: isMinimal ? p.text : kViolet,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Play ${pl.name}',
                        onPressed: () {
                          final t = store.tracksOf(pl);
                          if (t.isNotEmpty) playerService.playTracks(t);
                        },
                        icon: Icon(Icons.play_arrow_rounded, color: isMinimal ? p.bg : Colors.white),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
          Text('${pl.trackIds.length} songs', style: _muted(12)),
        ]),
      ),
    );
  }
}

/// One song in a list. Click plays [list] from here; right click for options.
class TrackRow extends StatefulWidget {
  final Track track;
  final List<Track> list;
  final int index;
  final PlaylistInfo? playlist;
  const TrackRow(this.track, {super.key, required this.list, required this.index, this.playlist});

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final t = widget.track;
    final playing = playerService.current?.id == t.id;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onSecondaryTap: () => showSongMenu(context, t, playlist: widget.playlist),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => playerService.playTracks(widget.list, start: widget.index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: hover ? p.text.withValues(alpha: 0.05) : null, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              TrackArt(t, size: 40, radius: 8),
              const SizedBox(width: 14),
              Expanded(
                flex: 5,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: playing ? p.accent : p.text, fontWeight: FontWeight.w500)),
                  Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: _muted(12)),
                ]),
              ),
              Expanded(flex: 3, child: Text(t.folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: _muted(12))),
              SizedBox(width: 48, child: Text(fmtTime(Duration(seconds: t.duration.round())), textAlign: TextAlign.right, style: _muted(12))),
              IconButton(
                tooltip: 'More',
                onPressed: () => showSongMenu(context, t, playlist: widget.playlist),
                icon: Icon(Icons.more_horiz_rounded, color: hover ? p.text : Colors.transparent),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ============================================================ Songs
class SongsPage extends StatefulWidget {
  const SongsPage({super.key});

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, playerService]),
      builder: (context, _) {
        final words = q.toLowerCase().split(' ').where((w) => w.isNotEmpty);
        final all = store.allTracks.where((t) {
          final s = '${t.title} ${t.artist} ${t.album}'.toLowerCase();
          return words.every(s.contains);
        }).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 28, 30, 12),
            child: Row(children: [
              Expanded(child: Text('Songs', style: _h1())),
              SizedBox(
                width: 300,
                child: TextField(
                  onChanged: (v) => setState(() => q = v),
                  decoration: const InputDecoration(hintText: 'Find in your songs', prefixIcon: Icon(Icons.filter_list_rounded), isDense: true),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                style: _primary(),
                onPressed: all.isEmpty ? null : () => playerService.playTracks(all, shuffle: true),
                icon: const Icon(Icons.shuffle_rounded, size: 18),
                label: const Text('Shuffle'),
              ),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              itemCount: all.length,
              itemExtent: 58,
              itemBuilder: (context, i) => TrackRow(all[i], list: all, index: i),
            ),
          ),
        ]);
      },
    );
  }
}

// ============================================================ Playlist
const _sorts = [('pc', 'My order'), ('recent', 'Recently added'), ('title', 'A–Z'), ('artist', 'Artist')];

/// When each playlist was last checked for new songs on open (this run of the app).
final Map<String, DateTime> _checkedAt = {};

class PlaylistPage extends StatefulWidget {
  final String folder;
  const PlaylistPage({super.key, required this.folder});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  @override
  void initState() {
    super.initState();
    _checkForNewSongs();
  }

  /// Opening a downloaded playlist checks its link for new songs (at most every
  /// 10 minutes). Songs removed from the playlist online stay on this PC.
  void _checkForNewSongs() {
    final f = widget.folder;
    final e = engine.playlists.where((x) => x['folder'] == f).firstOrNull;
    if (e == null || e['has_synced'] != true || engine.syncing) return;
    final last = _checkedAt[f];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 10)) return;
    _checkedAt[f] = DateTime.now();
    engine.syncFolders([f]);
  }

  @override
  Widget build(BuildContext context) {
    final folder = widget.folder;
    return ListenableBuilder(
      listenable: Listenable.merge([store, engine, playerService]),
      builder: (context, _) {
        final p = pal;
        final pl = store.playlistByFolder(folder);
        final link = '${engine.playlists.where((x) => x['folder'] == folder).firstOrNull?['url'] ?? ''}';
        if (pl == null || store.tracksOf(pl).isEmpty) {
          if (link.isNotEmpty) return _OnlinePlaylist(folder: folder, link: link);
          if (pl == null) return Center(child: Text('This playlist is gone.', style: _muted()));
        }
        final sort = store.playlistSort[folder] ?? 'pc';
        var tracks = store.tracksOf(pl);
        tracks = switch (sort) {
          'recent' => LibraryStore.sortTracks(tracks, TrackSort.recentlyAdded),
          'title' => LibraryStore.sortTracks(tracks, TrackSort.title),
          'artist' => LibraryStore.sortTracks(tracks, TrackSort.artist),
          _ => tracks,
        };
        final onPc = engine.playlists.any((e) => e['folder'] == folder);
        final secs = tracks.fold<double>(0, (s, t) => s + t.duration);
        return ListView(padding: const EdgeInsets.fromLTRB(30, 28, 30, 30), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ArtImage(file: store.coverFor(pl), size: 170, radius: 26, fallback: Icons.queue_music_rounded),
            const SizedBox(width: 24),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(pl.name, style: _h1().copyWith(fontSize: 34)),
                const SizedBox(height: 4),
                Text('${tracks.length} songs · ${(secs / 3600).floor()} h ${((secs % 3600) / 60).round()} min', style: _muted()),
                const SizedBox(height: 16),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  FilledButton.icon(
                    style: _primary(),
                    onPressed: tracks.isEmpty ? null : () => playerService.playTracks(tracks, shuffle: false),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play'),
                  ),
                  _pill('Shuffle', icon: Icons.shuffle_rounded, onTap: tracks.isEmpty ? null : () => playerService.playTracks(tracks, shuffle: true)),
                  if (onPc)
                    _pill(engine.syncing ? 'Syncing…' : 'Sync now', icon: Icons.sync_rounded, onTap: engine.syncing ? null : () async {
                      final e = await engine.syncFolders([folder]);
                      if (e != null && context.mounted) dToast(context, e);
                    }),
                  if (onPc) _PlaylistMore(folder: folder, title: pl.name),
                ]),
              ]),
            ),
          ]),
          const SizedBox(height: 22),
          if (onPc)
            Material(
              color: p.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => openSearch('', folder: folder),
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
                  child: Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(color: Color(0xFFE0403B), shape: BoxShape.circle),
                      child: const Icon(Icons.add_rounded, color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Add songs from the web', style: TextStyle(color: p.text, fontWeight: FontWeight.w600))),
                    Icon(Icons.search_rounded, color: p.muted, size: 18),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Row(children: [
            Text('Sort', style: _muted(12)),
            const SizedBox(width: 10),
            for (final (id, label) in _sorts)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: sort == id,
                  showCheckmark: false,
                  onSelected: (_) {
                    store.playlistSort[folder] = id;
                    store.changed();
                  },
                ),
              ),
            const Spacer(),
            Text('Saved for this playlist', style: _muted(11)),
          ]),
          const SizedBox(height: 10),
          for (var i = 0; i < tracks.length; i++) TrackRow(tracks[i], list: tracks, index: i, playlist: pl),
          if (tracks.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text('No songs yet. Sync this playlist to save its songs.', style: _muted())),
        ]);
      },
    );
  }
}

class _PlaylistMore extends StatelessWidget {
  final String folder, title;
  const _PlaylistMore({required this.folder, required this.title});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (v) async {
        switch (v) {
          case 'rename':
            final ctrl = TextEditingController(text: title);
            final name = await showDialog<String>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Rename playlist'),
                content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Rename')),
                ],
              ),
            );
            if (name != null && name.trim().isNotEmpty) await engine.renamePlaylist(folder, name.trim());
          case 'folder':
            await engine.open('${engine.masterFolder}\\$folder');
          case 'remove':
          case 'delete':
            final del = v == 'delete';
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(del ? 'Delete "$title"?' : 'Remove "$title"?'),
                content: Text(del
                    ? 'SpotVault forgets this playlist and moves its folder to the Recycle Bin.'
                    : 'SpotVault forgets this playlist. Its songs stay in your music folder.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(del ? 'Delete' : 'Remove')),
                ],
              ),
            );
            if (ok == true) {
              await engine.removePlaylist(folder, deleteFiles: del);
              dPage.value = DPage.home;
            }
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'folder', child: Text('Show in folder')),
        PopupMenuItem(value: 'remove', child: Text('Remove from SpotVault')),
        PopupMenuItem(value: 'delete', child: Text('Delete playlist and songs')),
      ],
    );
  }
}

// ============================================================ Search the web
class SearchPage extends StatefulWidget {
  final String initial;
  const SearchPage({super.key, this.initial = ''});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController ctrl = TextEditingController(text: widget.initial);
  List<Map<String, dynamic>> results = [];
  final Set<String> picked = {};
  bool busy = false;
  String error = '';
  String? folder = dSearchFolder;

  @override
  void initState() {
    super.initState();
    if (widget.initial.isNotEmpty) _search();
  }

  @override
  void dispose() {
    ctrl.dispose();
    playerService.stopPreview();
    super.dispose();
  }

  Future<void> _search() async {
    final q = ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final r = await http
          .get(Uri(scheme: 'http', host: '127.0.0.1', port: EngineClient.port, path: '/api/search', queryParameters: {'q': q}),
              headers: {'X-SpotVault-Pin': engine.token})
          .timeout(const Duration(seconds: 40));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      results = [for (final x in (j['results'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
      if (r.statusCode != 200) error = '${j['error'] ?? 'Search failed'}';
      picked.clear();
    } catch (e) {
      error = 'Search failed. Check your internet connection.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _preview(Map<String, dynamic> r) async {
    final key = '${r['url']}';
    if (playerService.previewing && playerService.previewKey == key) {
      await playerService.stopPreview();
      return;
    }
    final uri = Uri(scheme: 'http', host: '127.0.0.1', port: EngineClient.port, path: '/api/preview', queryParameters: {'url': key, 'pin': engine.token});
    try {
      await playerService.playPreview(uri, key: key, title: '${r['title']}', artist: '${r['artist'] ?? ''}', artUrl: '${r['thumb'] ?? ''}');
    } catch (_) {
      if (mounted) dToast(context, "Couldn't play a preview of that song.");
    }
  }

  Future<void> _save() async {
    if (folder == null) {
      dToast(context, 'Pick a playlist to save into.');
      return;
    }
    final e = await engine.downloadSongs(folder!, picked.toList());
    if (!mounted) return;
    if (e != null) {
      dToast(context, e);
    } else {
      dToast(context, 'Saving ${picked.length} song${picked.length == 1 ? '' : 's'}. See Sync & downloads.');
      setState(picked.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final pcLists = engine.playlists;
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 28, 30, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Find songs', style: _h1()),
            const SizedBox(height: 4),
            Text('Searches YouTube Music, SoundCloud and YouTube. Pick songs and save them into a playlist.', style: _muted()),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(hintText: 'Song, artist or link', prefixIcon: Icon(Icons.search_rounded)),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(style: _primary(), onPressed: busy ? null : _search, child: Text(busy ? 'Searching…' : 'Search')),
            ]),
          ]),
        ),
        if (error.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 30), child: Text(error, style: TextStyle(color: p.danger))),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: results.length,
            itemBuilder: (context, i) {
              final r = results[i];
              final url = '${r['url']}';
              final on = picked.contains(url);
              final previewing = playerService.previewing && playerService.previewKey == url;
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => on ? picked.remove(url) : picked.add(url)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(children: [
                    Checkbox(value: on, onChanged: (_) => setState(() => on ? picked.remove(url) : picked.add(url))),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: (r['thumb'] ?? '') == ''
                          ? Container(width: 44, height: 44, color: p.card)
                          : Image.network('${r['thumb']}', width: 44, height: 44, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(width: 44, height: 44, color: p.card)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w500)),
                        Text('${r['artist'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: _muted(12)),
                      ]),
                    ),
                    Text('${r['duration'] ?? ''}', style: _muted(12)),
                    IconButton(
                      tooltip: previewing ? 'Stop preview' : 'Preview',
                      onPressed: () => _preview(r),
                      icon: Icon(previewing ? Icons.stop_circle_outlined : Icons.play_circle_outline_rounded),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: picked.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(30, 6, 30, 18),
                  child: Row(children: [
                    Text('${picked.length} picked', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('Save into', style: _muted(13)),
                    const SizedBox(width: 10),
                    DropdownButton<String>(
                      value: pcLists.any((e) => e['folder'] == folder) ? folder : null,
                      hint: const Text('Pick a playlist'),
                      items: [for (final e in pcLists) DropdownMenuItem(value: '${e['folder']}', child: Text('${e['title']}'))],
                      onChanged: (v) => setState(() => folder = v),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(style: _primary(), onPressed: _save, child: const Text('Save songs')),
                  ]),
                ),
        ),
      ]),
    );
  }
}

// ============================================================ Sync & downloads
class _SyncStrip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = pal;
    final s = engine.sync;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => dPage.value = DPage.sync,
      child: _Card(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3, value: engine.progress, color: p.accent, backgroundColor: p.track)),
          const SizedBox(width: 14),
          Expanded(child: Text('Syncing ${s['playlist'] ?? ''} · ${s['label'] ?? ''}', style: TextStyle(color: p.text, fontWeight: FontWeight.w500))),
          Text('${(engine.progress * 100).round()}%', style: _muted(13)),
        ]),
      ),
    );
  }
}

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final link = TextEditingController();
  String tab = 'fail';
  Map<String, dynamic>? report;
  bool adding = false;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    _loadReport();
    engine.addListener(_onEngine);
  }

  void _onEngine() {
    if (_wasRunning && !engine.syncing) _loadReport();
    _wasRunning = engine.syncing;
  }

  @override
  void dispose() {
    engine.removeListener(_onEngine);
    link.dispose();
    super.dispose();
  }

  Future<void> _loadReport() async {
    try {
      final r = await engine.report();
      if (mounted) setState(() => report = r);
    } catch (_) {}
  }

  Future<void> _add() async {
    setState(() => adding = true);
    final before = engine.playlists.map((p) => p['folder']).toSet();
    final e = await engine.addPlaylist(link.text.trim());
    if (!mounted) return;
    setState(() => adding = false);
    if (e != null) {
      dToast(context, e);
      return;
    }
    link.clear();
    await engine.refresh();
    final added = engine.playlists.map((p) => '${p['folder']}').where((f) => !before.contains(f)).toList();
    if (added.isNotEmpty) await engine.syncFolders(added);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final p = pal;
        final s = engine.sync;
        final counts = (s['counts'] as Map?) ?? const {};
        final lr = engine.lastReport;
        final lc = (lr?['counts'] as Map?) ?? const {};
        return ListView(padding: const EdgeInsets.fromLTRB(30, 28, 30, 30), children: [
          Text('Sync & downloads', style: _h1()),
          const SizedBox(height: 4),
          Text('Paste a Spotify, YouTube or SoundCloud playlist link to save it.', style: _muted()),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: TextField(
                controller: link,
                onSubmitted: (_) => adding ? null : _add(),
                decoration: const InputDecoration(hintText: 'https://open.spotify.com/playlist/…', prefixIcon: Icon(Icons.link_rounded)),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(style: _primary(), onPressed: adding ? null : _add, child: Text(adding ? 'Adding…' : 'Save playlist')),
            const SizedBox(width: 10),
            engine.syncing
                ? _pill(s['stopping'] == true ? 'Stopping…' : 'Stop', icon: Icons.stop_rounded, onTap: s['stopping'] == true ? null : engine.stop)
                : _pill('Sync all', icon: Icons.sync_rounded, onTap: () async {
                    final e = await engine.syncAll();
                    if (e != null && context.mounted) dToast(context, e);
                  }),
          ]),
          const SizedBox(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: _Card(
                child: Row(children: [
                  _Ring(value: engine.syncing ? engine.progress : (lr == null ? 0 : 1), label: engine.syncing ? '${(engine.progress * 100).round()}%' : 'Ready'),
                  const SizedBox(width: 22),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(engine.syncing ? 'SYNCING NOW' : 'IDLE', style: TextStyle(color: p.accent, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                      const SizedBox(height: 6),
                      Text(engine.syncing ? '${s['playlist'] ?? ''}' : 'Everything is saved', style: _h2()),
                      const SizedBox(height: 4),
                      Text(engine.syncing ? '${s['label'] ?? ''}  ·  ${counts['done'] ?? 0} saved, ${counts['skip'] ?? 0} skipped, ${counts['fail'] ?? 0} failed' : 'Press Sync all to check every playlist for new songs.',
                          style: _muted(13)),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 300,
              child: _Card(
                child: Wrap(spacing: 28, runSpacing: 14, children: [
                  _Stat('${store.tracks.length}', 'songs saved'),
                  _Stat('${engine.playlists.length}', 'playlists'),
                  _Stat('${lc['skip'] ?? 0}', 'skipped last sync', color: const Color(0xFFE8B04A)),
                  _Stat('${lc['fail'] ?? 0}', 'failed last sync', color: p.danger),
                ]),
              ),
            ),
          ]),
          if (engine.syncing && engine.feed.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Card(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Live', style: _h2().copyWith(fontSize: 15)),
                const SizedBox(height: 6),
                for (final e in engine.feed.reversed.take(6))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      _Dot(e.kind),
                      const SizedBox(width: 10),
                      Expanded(child: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 13))),
                      SizedBox(width: 340, child: Text(e.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: _muted(12))),
                    ]),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 18),
          _ReportCard(report: report, tab: tab, onTab: (t) => setState(() => tab = t), onReload: _loadReport),
          const SizedBox(height: 18),
          _PlaylistsCard(),
        ]);
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String value, label;
  final Color? color;
  const _Stat(this.value, this.label, {this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 100,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: color ?? pal.text)),
          Text(label, style: _muted(12)),
        ]),
      );
}

class _Dot extends StatelessWidget {
  final String kind;
  const _Dot(this.kind);

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: switch (kind) {
            'done' => const Color(0xFF7FC29B),
            'skip' => const Color(0xFFE8B04A),
            'fail' => pal.danger,
            _ => pal.muted,
          },
        ),
      );
}

/// Progress ring that eases to each new value.
class _Ring extends StatelessWidget {
  final double value;
  final String label;
  const _Ring({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => SizedBox(
        width: 112,
        height: 112,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(child: CircularProgressIndicator(value: v, strokeWidth: 8, strokeCap: StrokeCap.round, color: p.accent, backgroundColor: p.track)),
          Text(label, style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final Map<String, dynamic>? report;
  final String tab;
  final ValueChanged<String> onTab;
  final VoidCallback onReload;
  const _ReportCard({required this.report, required this.tab, required this.onTab, required this.onReload});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final entries = [for (final e in (report?['entries'] as List? ?? const [])) (e as Map).cast<String, dynamic>()];
    int count(String k) => entries.where((e) => e['kind'] == k).length;
    final rows = entries.where((e) => e['kind'] == tab).toList();
    final failedPlaylists = entries.where((e) => e['kind'] == 'fail').map((e) => '${e['playlist']}').where((s) => s.isNotEmpty).toSet().toList();
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Last sync report', style: _h2())),
          for (final (id, label) in [('fail', 'Failed'), ('skip', 'Skipped'), ('done', 'Saved')])
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ChoiceChip(
                avatar: _Dot(id),
                label: Text('$label ${count(id)}'),
                selected: tab == id,
                showCheckmark: false,
                onSelected: (_) => onTab(id),
              ),
            ),
          const SizedBox(width: 8),
          if (failedPlaylists.isNotEmpty)
            _pill('Retry failed', icon: Icons.refresh_rounded, onTap: engine.syncing ? null : () => engine.syncFolders(failedPlaylists)),
          IconButton(
            tooltip: 'Copy the list',
            onPressed: () {
              final text = [
                for (final e in entries.where((e) => e['kind'] != 'done')) '${e['kind'] == 'fail' ? 'FAILED' : 'SKIPPED'}  ${e['title']}  (${e['playlist']}): ${e['detail']}'
              ].join('\n');
              Clipboard.setData(ClipboardData(text: text));
              dToast(context, 'Copied');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ]),
        const SizedBox(height: 8),
        if (report == null || entries.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text('No sync yet. After a sync, every saved, skipped and failed song is listed here with the reason.', style: _muted(13)))
        else if (rows.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(tab == 'fail' ? 'Nothing failed.' : 'Nothing here.', style: _muted(13)))
        else
          for (final e in rows.take(300))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
              child: Row(children: [
                Expanded(
                  flex: 4,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w500)),
                    Text('${e['playlist']}', style: _muted(12)),
                  ]),
                ),
                const SizedBox(width: 12),
                _Dot('${e['kind']}'),
                const SizedBox(width: 8),
                Expanded(flex: 5, child: Text('${e['detail']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text.withValues(alpha: 0.8), fontSize: 13))),
                const SizedBox(width: 10),
                if (e['kind'] == 'done' && '${e['path']}'.isNotEmpty)
                  _pill('Show file', onTap: () => engine.open('${e['path']}'))
                else if (e['kind'] != 'done')
                  _pill('Search', onTap: () => openSearch(_queryFor('${e['title']}'), folder: '${e['playlist']}')),
              ]),
            ),
      ]),
    );
  }
}

/// A playlist that isn't downloaded yet: its songs, streamed from the internet.
class _OnlinePlaylist extends StatefulWidget {
  final String folder, link;
  const _OnlinePlaylist({required this.folder, required this.link});

  @override
  State<_OnlinePlaylist> createState() => _OnlinePlaylistState();
}

class _OnlinePlaylistState extends State<_OnlinePlaylist> {
  List<Map<String, dynamic>>? songs;
  String error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => error = '');
    try {
      final t = await engine.tracks(widget.link);
      if (mounted) setState(() => songs = t);
    } catch (e) {
      if (mounted) setState(() => error = '$e'.replaceFirst('Exception: ', ''));
    }
  }

  String get _key => 'online:${widget.folder}';

  Future<void> _play(int start) async {
    final list = songs ?? const [];
    final items = <(Uri, Track)>[
      for (final (i, t) in list.indexed)
        (
          engine.streamFor(t),
          Track(
            id: 'online:${widget.folder}:$i',
            path: '',
            title: '${t['title']}',
            artist: '${t['artist'] ?? ''}',
            album: widget.folder,
            size: 0,
            mtime: 0,
            duration: ((t['secs'] as num?) ?? 0).toDouble(),
            addedAt: 0,
            hasArt: false,
          ),
        ),
    ];
    try {
      await playerService.playOnline(items, start: start, key: _key);
    } catch (_) {
      if (mounted) dToast(context, "Couldn't play that song online. Check your internet.");
    }
  }

  Future<void> _download() async {
    final e = await engine.syncFolders([widget.folder]);
    if (!mounted) return;
    if (e != null) {
      dToast(context, e);
    } else {
      dPage.value = DPage.sync;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final e = engine.playlists.where((x) => x['folder'] == widget.folder).firstOrNull;
    final title = '${e?['title'] ?? widget.folder}';
    final list = songs;
    final mine = playerService.onlineList && playerService.previewKey == _key;
    final playingId = mine ? playerService.current?.id : null;
    return ListView(padding: const EdgeInsets.fromLTRB(30, 28, 30, 30), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Container(
          width: 170,
          height: 170,
          decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(26), border: Border.all(color: p.line)),
          child: Icon(Icons.wifi_rounded, size: 54, color: p.muted),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ONLINE PLAYLIST', style: _muted(12).copyWith(letterSpacing: 1.1, fontWeight: FontWeight.w700)),
            Text(title, style: _h1().copyWith(fontSize: 34)),
            const SizedBox(height: 4),
            Text(list == null ? 'Loading the songs…' : '${list.length} songs · streaming, not downloaded yet', style: _muted()),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: [
              FilledButton.icon(style: _primary(), onPressed: (list ?? const []).isEmpty ? null : () => _play(0), icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play online')),
              _pill(engine.syncing ? 'Syncing…' : 'Download all', icon: Icons.download_rounded, onTap: engine.syncing ? null : _download),
              _PlaylistMore(folder: widget.folder, title: title),
            ]),
          ]),
        ),
      ]),
      const SizedBox(height: 22),
      if (error.isNotEmpty)
        Row(children: [Expanded(child: Text(error, style: TextStyle(color: p.danger))), _pill('Try again', icon: Icons.refresh_rounded, onTap: _load)])
      else if (list == null)
        Padding(padding: const EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: p.accent)))
      else if (list.isEmpty)
        Text('This playlist is empty, or private.', style: _muted())
      else
        for (final (i, t) in list.indexed)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            leading: SizedBox(
              width: 28,
              child: Center(
                child: playingId == 'online:${widget.folder}:$i'
                    ? Icon(Icons.graphic_eq_rounded, color: p.accent, size: 20)
                    : Text('${i + 1}', style: _muted(13)),
              ),
            ),
            title: Text('${t['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w500)),
            subtitle: Text('${t['artist'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: _muted(12)),
            trailing: Text(fmtTime(Duration(seconds: ((t['secs'] as num?) ?? 0).toInt())), style: _muted(12)),
            onTap: () => _play(i),
          ),
    ]);
  }
}

String _queryFor(String title) => title
    .replaceAll(RegExp(r'\(\s*from[^)]*\)', caseSensitive: false), '')
    .replaceAll(RegExp(r'[\[\(][^\]\)]*[\]\)]'), '')
    .replaceAll(' - ', ' ')
    .trim();

class _PlaylistsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = pal;
    final lists = engine.playlists;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Saved playlists', style: _h2())),
          _pill('Open music folder', icon: Icons.folder_open_rounded, onTap: () => engine.open()),
        ]),
        const SizedBox(height: 8),
        for (final pl in lists)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
            child: Row(children: [
              Icon(
                switch ('${pl['source']}') { 'spotify' => Icons.album_rounded, 'soundcloud' => Icons.cloud_outlined, _ => Icons.smart_display_outlined },
                size: 18,
                color: p.muted,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('${pl['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w500))),
              SizedBox(width: 110, child: Text('${pl['songs']} songs', style: _muted(12))),
              SizedBox(width: 90, child: Text(_mb((pl['bytes'] as num?) ?? 0), style: _muted(12))),
              IconButton(tooltip: 'Open', onPressed: () => openPlaylist('${pl['folder']}'), icon: const Icon(Icons.chevron_right_rounded)),
              IconButton(
                tooltip: 'Sync this playlist',
                onPressed: engine.syncing ? null : () => engine.syncFolders(['${pl['folder']}']),
                icon: const Icon(Icons.sync_rounded, size: 19),
              ),
              IconButton(
                tooltip: 'Copy link',
                onPressed: () => Clipboard.setData(ClipboardData(text: '${pl['url']}')),
                icon: const Icon(Icons.link_rounded, size: 19),
              ),
            ]),
          ),
      ]),
    );
  }
}

String _mb(num bytes) => bytes > 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB';

// ============================================================ Settings
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final name = TextEditingController(text: store.userName);
  final keyId = TextEditingController();
  final keySecret = TextEditingController();
  String keyMsg = '';
  String updateMsg = '';
  Map<String, dynamic>? update;

  @override
  void dispose() {
    name.dispose();
    keyId.dispose();
    keySecret.dispose();
    super.dispose();
  }

  Future<void> _setLook(String s) async {
    themeStyle.value = s;
    store.themeStyle = s;
    await store.save();
    setState(() {});
  }

  Future<void> _checkUpdate() async {
    setState(() => updateMsg = 'Checking…');
    try {
      final u = await engine.checkUpdate();
      setState(() {
        update = u['newer'] == true ? (u['info'] as Map).cast<String, dynamic>() : null;
        updateMsg = u['error'] != null
            ? '${u['error']}'
            : u['newer'] == true
                ? 'Version ${update!['version']} is ready.'
                : "You're on the latest version (${engine.state['version']}).";
      });
    } catch (_) {
      setState(() => updateMsg = "Couldn't check for updates.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final p = pal;
        final phone = engine.phone;
        final pin = '${phone['pin'] ?? ''}';
        final ips = [for (final i in (phone['ips'] as List? ?? const [])) '$i'];
        return ListView(padding: const EdgeInsets.fromLTRB(30, 28, 30, 30), children: [
          Text('Settings', style: _h1()),
          const SizedBox(height: 20),
          _Section('You', [
            Row(children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Your name', isDense: true),
                  onSubmitted: (v) async {
                    store.userName = v.trim();
                    await store.save();
                    if (context.mounted) dToast(context, 'Saved');
                  },
                ),
              ),
              const SizedBox(width: 10),
              _pill('Save', onTap: () async {
                store.userName = name.text.trim();
                await store.save();
                if (context.mounted) dToast(context, 'Saved');
              }),
            ]),
          ]),
          _Section('Look', [
            Wrap(spacing: 10, children: [
              ChoiceChip(label: const Text('Minimal'), selected: isMinimal, onSelected: (_) => _setLook('minimal')),
              ChoiceChip(label: const Text('Crimson (classic)'), selected: !isMinimal, onSelected: (_) => _setLook('crimson')),
              const SizedBox(width: 14),
              ChoiceChip(
                label: const Text('Dark'),
                selected: darkMode.value,
                onSelected: (_) async {
                  darkMode.value = true;
                  store.darkTheme = true;
                  await store.save();
                  setState(() {});
                },
              ),
              ChoiceChip(
                label: const Text('Light'),
                selected: !darkMode.value,
                onSelected: (_) async {
                  darkMode.value = false;
                  store.darkTheme = false;
                  await store.save();
                  setState(() {});
                },
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              SizedBox(width: 90, child: Text('Player', style: TextStyle(color: p.text))),
              ChoiceChip(
                label: const Text('Classic'),
                selected: store.playerLook != 'focus',
                onSelected: (_) async {
                  store.playerLook = 'classic';
                  store.changed();
                  await store.save();
                  setState(() {});
                },
              ),
              const SizedBox(width: 10),
              ChoiceChip(
                label: const Text('Focus'),
                selected: store.playerLook == 'focus',
                onSelected: (_) async {
                  store.playerLook = 'focus';
                  store.changed();
                  await store.save();
                  setState(() {});
                },
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Focus: one column, the ring around the cover is the timeline, lyrics in a card.', style: _muted(12))),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              SizedBox(width: 90, child: Text('Glass', style: TextStyle(color: p.text))),
              Text('Clear', style: _muted(12)),
              Expanded(
                child: ValueListenableBuilder<double>(
                  valueListenable: glassSolid,
                  builder: (context, v, _) => Slider(
                    value: v,
                    onChanged: (x) => glassSolid.value = x,
                    onChangeEnd: (x) async {
                      store.glassSolid = x;
                      await store.save();
                    },
                  ),
                ),
              ),
              Text('Solid', style: _muted(12)),
            ]),
          ]),
          _Section('Song list', [
            Text('Every playlist and song as plain text. Keep it as a backup, or import a list from your phone to download all of it.', style: _muted(13)),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _pill('Copy my list', icon: Icons.copy_rounded, onTap: () {
                Clipboard.setData(ClipboardData(text: buildSongList(store)));
                dToast(context, 'Copied ${store.tracks.length} songs');
              }),
              _pill('Save as .txt', icon: Icons.save_alt_rounded, onTap: () async {
                final loc = await getSaveLocation(suggestedName: 'SpotVault song list.txt', acceptedTypeGroups: const [XTypeGroup(label: 'Text', extensions: ['txt'])]);
                if (loc == null) return;
                await File(loc.path).writeAsString(buildSongList(store));
                if (context.mounted) dToast(context, 'Saved');
              }),
              FilledButton.icon(style: _primary(), onPressed: () => importSongListDialog(context), icon: const Icon(Icons.download_rounded, size: 16), label: const Text('Import a list')),
            ]),
          ]),
          _Section('Music folder', [
            Row(children: [
              Expanded(child: Text(engine.masterFolder, style: TextStyle(color: p.text))),
              _pill('Open', onTap: () => engine.open()),
              const SizedBox(width: 8),
              _pill('Change…', onTap: () async {
                final dir = await getDirectoryPath(initialDirectory: engine.masterFolder, confirmButtonText: 'Use this folder');
                if (dir != null) await engine.setMasterFolder(dir);
              }),
            ]),
            const SizedBox(height: 6),
            Text('Each playlist is a folder in here. Changing it does not move your songs.', style: _muted(12)),
          ]),
          _Section('Phone link', [
            Text(phone['running'] == true ? 'Ready for phones on this Wi-Fi.' : 'Phone link is off: ${phone['error'] ?? ''}', style: TextStyle(color: p.text)),
            const SizedBox(height: 10),
            Wrap(spacing: 30, runSpacing: 10, children: [
              _Stat(ips.isEmpty ? 'No network' : '${ips.first}:${phone['port']}', 'address on your phone'),
              _Stat(pin.length == 6 ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin, 'PIN'),
            ]),
            const SizedBox(height: 10),
            if (ips.isNotEmpty && pin.isNotEmpty)
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: QrImageView(data: pcLinkFor(ips.first, (phone['port'] as num?)?.toInt() ?? 50505, pin), size: 150, backgroundColor: Colors.white),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text('On your phone: Sync → Scan the code on your PC. Same Wi-Fi.', style: _muted(13))),
              ]),
            const SizedBox(height: 10),
            _pill('New PIN', onTap: engine.newPin),
          ]),
          _Section('Your own Spotify key (optional)', [
            Text(
                'Spotify playlists sync through a shared key that Spotify slows down. Your own free key makes new songs faster.\n'
                '1. Open developer.spotify.com/dashboard and log in.  2. Create app (any name).  3. Redirect URI: http://127.0.0.1:8888/callback.  '
                '4. Tick Web API and save.  5. Copy the Client ID and Client secret here.',
                style: _muted(13)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: keyId, decoration: InputDecoration(labelText: engine.state['spotify_key'] == true ? 'Client ID (your key is in use)' : 'Client ID', isDense: true))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: keySecret, obscureText: true, decoration: const InputDecoration(labelText: 'Client secret', isDense: true))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _pill('Open the Spotify dashboard', onTap: () => launchUrl(Uri.parse('https://developer.spotify.com/dashboard'))),
              const Spacer(),
              if (keyMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(right: 12), child: Text(keyMsg, style: _muted(13))),
              _pill('Remove key', onTap: () async {
                final e = await engine.setSpotifyKey('', '');
                setState(() => keyMsg = e ?? 'Removed. Syncs use the shared key again.');
              }),
              const SizedBox(width: 8),
              FilledButton(
                style: _primary(),
                onPressed: () async {
                  final e = await engine.setSpotifyKey(keyId.text.trim(), keySecret.text.trim());
                  setState(() => keyMsg = e ?? 'Saved. Your own key is in use.');
                  if (e == null) {
                    keyId.clear();
                    keySecret.clear();
                  }
                },
                child: const Text('Save key'),
              ),
            ]),
          ]),
          _Section('Updates', [
            Row(children: [
              Text('SpotVault ${engine.state['version'] ?? ''}', style: TextStyle(color: p.text)),
              const SizedBox(width: 16),
              Expanded(child: Text(updateMsg, style: _muted(13))),
              if (update != null)
                FilledButton(
                  style: _primary(),
                  onPressed: engine.state['update_progress'] != null ? null : () => engine.installUpdate(),
                  child: Text(engine.state['update_progress'] != null ? 'Downloading ${(((engine.state['update_progress'] as num?) ?? 0) * 100).round()}%' : 'Install update'),
                )
              else
                _pill('Check for updates', onTap: _checkUpdate),
            ]),
          ]),
        ]);
      },
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(this.title, this.children);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: _h2()), const SizedBox(height: 12), ...children])),
      );
}
