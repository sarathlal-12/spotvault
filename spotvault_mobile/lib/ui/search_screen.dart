import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../pc_link.dart';
import 'common.dart';

enum _Mode { library, online }

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final ctrl = TextEditingController();
  _Mode mode = _Mode.library;

  // Online search state
  List<OnlineSong> results = [];
  bool searching = false;
  String? error;
  String lastQuery = '';
  int _searchId = 0;
  String? _previewLoading;

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  Future<void> _runOnline() async {
    final q = ctrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final id = ++_searchId;
    setState(() {
      searching = true;
      error = null;
      lastQuery = q;
    });
    try {
      final r = await pcLink.search(q);
      if (!mounted || id != _searchId) return;
      setState(() => results = r);
    } catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() {
        results = [];
        error = e is PcException ? e.message : 'Search failed. Check that SpotVault is open on your PC.';
      });
    } finally {
      if (mounted && id == _searchId) setState(() => searching = false);
    }
  }

  Future<void> _togglePreview(OnlineSong song) async {
    if (playerService.previewing && playerService.previewKey == song.url) {
      await playerService.stopPreview();
      return;
    }
    setState(() => _previewLoading = song.url);
    try {
      final uri = await pcLink.previewUri(song);
      await playerService.playPreview(uri, key: song.url, title: song.title, artist: song.artist, artUrl: song.thumb);
    } catch (e) {
      if (mounted) _snack(e is PcException ? e.message : "Couldn't play this song. Try another one.");
    } finally {
      if (mounted) setState(() => _previewLoading = null);
    }
  }

  Future<void> _download(OnlineSong song) async {
    if (store.playlists.isEmpty) {
      _snack('No playlists yet. Sync your playlists from the PC first.');
      return;
    }
    final pl = await showModalBottomSheet<PlaylistInfo>(
      context: context,
      backgroundColor: kSurface,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _PlaylistPicker(song: song),
    );
    if (pl == null) return;
    _snack('Saving "${song.title}" to ${pl.title}…');
    pcLink.download(song, pl);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final online = mode == _Mode.online;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(value: _Mode.library, label: Text('Your library'), icon: Icon(Icons.library_music_outlined)),
                ButtonSegment(value: _Mode.online, label: Text('Find new songs'), icon: Icon(Icons.travel_explore)),
              ],
              selected: {mode},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                backgroundColor: kCard,
                foregroundColor: kMuted,
                selectedBackgroundColor: kAccent,
                selectedForegroundColor: Colors.white,
                side: BorderSide.none,
              ),
              onSelectionChanged: (s) {
                setState(() => mode = s.first);
                if (mode == _Mode.library) playerService.stopPreview();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: ctrl,
              onChanged: (_) {
                if (!online) setState(() {});
              },
              onSubmitted: (_) => online ? _runOnline() : null,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: online ? 'Search any song or artist' : 'Songs, artists or albums',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(ctrl.clear),
                      ),
                filled: true,
                fillColor: kCard,
                hintStyle: const TextStyle(color: kMuted),
                prefixIconColor: kMuted,
                suffixIconColor: kMuted,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: kAccent, width: 1.5),
                ),
              ),
            ),
          ),
          Expanded(child: online ? _onlineBody() : _libraryBody()),
        ],
      ),
    );
  }

  Widget _libraryBody() {
    final results = store.search(ctrl.text);
    if (ctrl.text.isEmpty) {
      return const _Hint(icon: Icons.library_music_outlined, text: 'Search the music on this phone');
    }
    if (results.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Not on this phone yet', style: TextStyle(color: kMuted)),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white),
            onPressed: () {
              setState(() => mode = _Mode.online);
              _runOnline();
            },
            icon: const Icon(Icons.travel_explore),
            label: Text('Find "${ctrl.text.trim()}"'),
          ),
        ],
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) => TrackTile(track: results[i], list: results, index: i),
    );
  }

  Widget _onlineBody() {
    return ListenableBuilder(
      listenable: Listenable.merge([pcLink, playerService]),
      builder: (context, _) {
        final jobs = pcLink.jobs.reversed.toList();
        return CustomScrollView(
          slivers: [
            if (jobs.isNotEmpty)
              SliverToBoxAdapter(child: _JobsPanel(jobs: jobs)),
            if (searching)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator(color: kAccent)),
              )
            else if (error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi_off_rounded, color: kMuted, size: 42),
                      const SizedBox(height: 12),
                      Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
                      const SizedBox(height: 16),
                      OutlinedButton(onPressed: _runOnline, child: const Text('Try again')),
                    ],
                  ),
                ),
              )
            else if (results.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _Hint(
                  icon: Icons.travel_explore,
                  text: lastQuery.isEmpty
                      ? 'Find any song, listen to it, then save it to one of your playlists.\nYour PC does the downloading, so keep SpotVault open on it.'
                      : 'No songs found for "$lastQuery".',
                ),
              )
            else
              SliverList.builder(
                itemCount: results.length,
                itemBuilder: (_, i) => _onlineTile(results[i]),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          ],
        );
      },
    );
  }

  Widget _onlineTile(OnlineSong s) {
    final isPreview = playerService.previewing && playerService.previewKey == s.url;
    final loading = _previewLoading == s.url ||
        (isPreview &&
            (playerService.player.processingState == ProcessingState.loading ||
                playerService.player.processingState == ProcessingState.buffering));
    final job = pcLink.jobFor(s);
    final subtitle = [s.artist, s.duration].where((x) => x.isNotEmpty).join(' · ');

    Widget dlButton;
    if (job == null || job.state == DlState.failed) {
      dlButton = IconButton(
        tooltip: 'Download',
        icon: Icon(job == null ? Icons.download_rounded : Icons.refresh, color: Colors.white),
        onPressed: () => _download(s),
      );
    } else if (job.state == DlState.saved) {
      dlButton = const Padding(
        padding: EdgeInsets.all(12),
        child: Icon(Icons.check_circle, color: kAccent),
      );
    } else {
      dlButton = const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: kAccent)),
      );
    }

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: _NetArt(url: s.thumb, size: 52),
      title: Text(s.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: isPreview ? kAccent : Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 12)),
      onTap: () => _togglePreview(s),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          loading
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
                )
              : IconButton(
                  tooltip: isPreview ? 'Stop' : 'Listen',
                  icon: Icon(isPreview ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                      color: isPreview ? kAccent : Colors.white, size: 30),
                  onPressed: () => _togglePreview(s),
                ),
          dlButton,
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: kAccent.withValues(alpha: 0.8), size: 44),
              const SizedBox(height: 14),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: kMuted, height: 1.4)),
            ],
          ),
        ),
      );
}

/// Cover art from the internet, with the usual music-note fallback.
class _NetArt extends StatelessWidget {
  final String url;
  final double size;
  const _NetArt({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      color: kCard,
      alignment: Alignment.center,
      child: Icon(Icons.music_note, color: kMuted, size: size * 0.45),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url.isEmpty
          ? fallback
          : Image.network(url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
              loadingBuilder: (_, child, p) => p == null ? child : fallback),
    );
  }
}

/// Bottom sheet: which playlist should the song go into?
class _PlaylistPicker extends StatelessWidget {
  final OnlineSong song;
  const _PlaylistPicker({required this.song});

  @override
  Widget build(BuildContext context) {
    final lists = store.playlists;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Row(
                children: [
                  _NetArt(url: song.thumb, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Text('Save to playlist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: lists.length,
                itemBuilder: (_, i) {
                  final p = lists[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: ArtImage(file: store.coverFor(p), size: 48, fallback: Icons.queue_music),
                    title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${p.trackIds.length} songs', style: const TextStyle(color: kMuted, fontSize: 12)),
                    onTap: () => Navigator.pop(context, p),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Download progress for songs the user saved from search.
class _JobsPanel extends StatelessWidget {
  final List<DlJob> jobs;
  const _JobsPanel({required this.jobs});

  @override
  Widget build(BuildContext context) {
    final anyDone = jobs.any((j) => j.finished);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Downloads', style: TextStyle(fontWeight: FontWeight.bold))),
              if (anyDone) TextButton(onPressed: pcLink.clearFinished, child: const Text('Clear')),
            ],
          ),
          for (final j in jobs.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  _stateIcon(j.state),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(j.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        Text(j.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: j.state == DlState.failed ? const Color(0xFFF43F5E) : kMuted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stateIcon(DlState s) => switch (s) {
        DlState.saved => const Icon(Icons.check_circle, color: kAccent, size: 20),
        DlState.failed => const Icon(Icons.error_outline, color: Color(0xFFF43F5E), size: 20),
        _ => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: kAccent)),
      };
}
