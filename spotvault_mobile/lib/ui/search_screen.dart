import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../pc_link.dart';
import 'aurora.dart';
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
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PlaylistPicker(song: song),
    );
    if (pl == null) return;
    final ghost = store.ghostQueue;
    _snack(ghost
        ? '"${song.title}" is in your Ghost Queue. It plays next once it reaches the phone.'
        : 'Saving "${song.title}" to ${pl.title}…');
    pcLink.download(song, pl, playWhenReady: ghost);
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
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Expanded(child: Text(online ? 'Find new songs' : 'Search', style: displayStyle(28))),
                const ThemeToggle(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _ModeSwitch(
              online: online,
              onChanged: (o) {
                setState(() => mode = o ? _Mode.online : _Mode.library);
                if (!o) playerService.stopPreview();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: TextField(
              controller: ctrl,
              onChanged: (_) {
                if (!online) setState(() {});
              },
              onSubmitted: (_) => online ? _runOnline() : null,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: online ? 'Search any song or artist' : 'Songs, artists or albums',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(ctrl.clear),
                      ),
                prefixIconColor: kAccent,
                suffixIconColor: kMuted,
              ),
            ),
          ),
          if (online)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
              child: Row(
                children: [
                  Container(width: 6, height: 6, decoration: const BoxDecoration(color: kCyan, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Searching through your PC · clean studio versions first',
                        style: TextStyle(fontSize: 12, color: kMuted)),
                  ),
                ],
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
          Text('Not on this phone yet', style: TextStyle(color: kMuted)),
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
      padding: const EdgeInsets.only(bottom: 180),
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
              SliverFillRemaining(
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
                      Icon(Icons.wifi_off_rounded, color: kMuted, size: 42),
                      const SizedBox(height: 12),
                      Text(error!, textAlign: TextAlign.center, style: TextStyle(color: kMuted)),
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
            const SliverToBoxAdapter(child: SizedBox(height: 180)),
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

    Widget saveButton;
    if (job == null || job.state == DlState.failed) {
      saveButton = Pressable(
        onTap: () => _download(s),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), border: Border.all(color: kLine)),
          child: Text(job == null ? 'Save' : 'Retry', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kText)),
        ),
      );
    } else if (job.state == DlState.saved) {
      saveButton = Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(gradient: kBrandGradient, borderRadius: BorderRadius.circular(99)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_rounded, size: 16, color: Colors.white),
          SizedBox(width: 4),
          Text('Saved', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
        ]),
      );
    } else {
      saveButton = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: kAccent)),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isPreview ? kViolet.withValues(alpha: pal.dark ? 0.14 : 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isPreview ? kViolet.withValues(alpha: 0.35) : Colors.transparent),
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: isPreview ? 'Stop preview of ${s.title}' : 'Preview ${s.title}',
            child: Pressable(
              onTap: () => _togglePreview(s),
              child: SizedBox(
                width: 54,
                height: 54,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    _NetArt(url: s.thumb, size: 54),
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.28), borderRadius: BorderRadius.circular(14)),
                    ),
                    if (isPreview && !loading) const _PreviewRing(),
                    loading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                        : Icon(isPreview ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 26),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () => _togglePreview(s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: isPreview ? kAccent : kText, fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          saveButton,
        ],
      ),
    );
  }
}

/// Library / Find new songs switch with a sliding highlight.
class _ModeSwitch extends StatelessWidget {
  final bool online;
  final ValueChanged<bool> onChanged;
  const _ModeSwitch({required this.online, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget option(String label, IconData icon, bool value) => Expanded(
          child: Semantics(
            button: true,
            selected: online == value,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(value),
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 18, color: online == value ? Colors.white : kMuted),
                    const SizedBox(width: 6),
                    Text(label,
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: online == value ? Colors.white : kMuted)),
                  ],
                ),
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: pal.dark ? pal.glass : pal.surface,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: kLine),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutBack,
            alignment: online ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  gradient: kBrandGradient,
                  borderRadius: BorderRadius.circular(99),
                  boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 6))],
                ),
              ),
            ),
          ),
          Row(children: [
            option('Your library', Icons.library_music_rounded, false),
            option('Find new songs', Icons.travel_explore_rounded, true),
          ]),
        ],
      ),
    );
  }
}

/// Expanding ring around the song being previewed.
class _PreviewRing extends StatefulWidget {
  const _PreviewRing();

  @override
  State<_PreviewRing> createState() => _PreviewRingState();
}

class _PreviewRingState extends State<_PreviewRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Transform.scale(
        scale: 1 + 0.35 * _c.value,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kCyan.withValues(alpha: 0.9 * (1 - _c.value)), width: 2),
          ),
        ),
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
              Text(text, textAlign: TextAlign.center, style: TextStyle(color: kMuted, height: 1.4)),
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
      borderRadius: BorderRadius.circular(14),
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
                        Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 12)),
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
                    subtitle: Text('${p.trackIds.length} songs', style: TextStyle(color: kMuted, fontSize: 12)),
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
      decoration: BoxDecoration(
        color: pal.dark ? pal.glass : pal.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(children: [
                  Text(jobs.any((j) => j.playWhenReady) ? 'Ghost Queue' : 'Downloads',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: kText)),
                  if (jobs.any((j) => j.playWhenReady)) ...[const SizedBox(width: 6), const NewTag()],
                ]),
              ),
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
        DlState.saved => Icon(Icons.check_circle, color: kAccent, size: 20),
        DlState.failed => const Icon(Icons.error_outline, color: Color(0xFFF43F5E), size: 20),
        _ => SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: kAccent)),
      };
}
