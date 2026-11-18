import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../ui/common.dart' show ArtImage, TrackArt;
import '../ui/wave_progress.dart';
import '../ui/welcome_screen.dart' show SpotVaultMark;
import 'desktop_pages.dart';
import 'desktop_player.dart';
import 'engine_client.dart';

/// Pages in the Windows app's sidebar.
enum DPage { home, songs, playlist, search, sync, jam, studio, settings }

final ValueNotifier<DPage> dPage = ValueNotifier(DPage.home);
final ValueNotifier<String> dPlaylist = ValueNotifier('');
final ValueNotifier<bool> dPlayerOpen = ValueNotifier(false);

void openPlaylist(String folder) {
  dPlaylist.value = folder;
  dPage.value = DPage.playlist;
}

String fmtTime(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// How solid the glass is, 0 (see-through) to 1 (solid); Settings → Look.
final ValueNotifier<double> glassSolid = ValueNotifier(store.glassSolid);

/// Frosted glass panel over the blurred cover.
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double opacity;

  /// Frosts whatever scrolls behind it (used by the player bar, which floats
  /// over the pages). Other panels sit on the already-soft cover backdrop.
  final bool frosted;
  const Glass({super.key, required this.child, this.radius = 28, this.padding, this.opacity = 1, this.frosted = false});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(valueListenable: glassSolid, builder: (context, solid, _) => _panel(solid));

  Widget _panel(double solid) {
    final p = pal;
    // The slider's default (0.35) gives the original look; 0 is clearer, 1 is solid.
    double a(double base) => solid >= 0.35 ? base + (1 - base) * (solid - 0.35) / 0.65 : base * (0.45 + 0.55 * solid / 0.35);

    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.dark
            ? Color.lerp(p.bg, Colors.white, 0.06)!.withValues(alpha: (a(frosted ? 0.93 : 0.82) * opacity).clamp(0.0, 1.0))
            : Colors.white.withValues(alpha: (a(frosted ? 0.86 : 0.62) * opacity).clamp(0.0, 1.0)),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.dark ? Colors.white.withValues(alpha: 0.11) : Colors.white.withValues(alpha: 0.7)),
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: frosted ? BackdropFilter(filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24), child: panel) : panel,
    );
  }
}

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Scaffold(
      backgroundColor: p.bg,
      body: Stack(fit: StackFit.expand, children: [
        const Positioned.fill(child: _CoverBackdrop()),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 104),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const _Rail(),
              const SizedBox(width: 14),
              Expanded(
                child: Glass(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const SizedBox(width: 230, child: _Sidebar()),
                    VerticalDivider(width: 1, color: p.line),
                    Expanded(
                      // Listens to the playlist too: switching from one playlist to another keeps
                      // dPage at DPage.playlist, so dPage alone wouldn't rebuild the page.
                      child: ListenableBuilder(
                        listenable: Listenable.merge([dPage, dPlaylist]),
                        builder: (context, _) => AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: SlideTransition(position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(a), child: child),
                          ),
                          child: KeyedSubtree(key: ValueKey('${dPage.value}${dPlaylist.value}'), child: pageFor(dPage.value)),
                        ),
                      ),
                    ),
                    LayoutBuilder(builder: (context, c) {
                      return MediaQuery.sizeOf(context).width < 1180 ? const SizedBox() : const SizedBox(width: 320, child: _NowPanel());
                    }),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        const Positioned(left: 0, right: 0, bottom: 16, child: Center(child: _PlayerBar())),
        // Full player with lyrics, over everything.
        ValueListenableBuilder<bool>(
          valueListenable: dPlayerOpen,
          builder: (context, open, _) => IgnorePointer(
            ignoring: !open,
            child: AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              child: AnimatedScale(
                scale: open ? 1 : 0.98,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                // Blurs the whole app behind the player, so only a soft haze shows through.
                child: open
                    ? ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40), child: const DesktopPlayer()))
                    : const SizedBox(),
              ),
            ),
          ),
        ),
        const Positioned(top: 26, left: 0, right: 0, child: _EngineBanner()),
      ]),
    );
  }
}

/// The current song's cover, blurred, behind the glass. Changes with each song.
class _CoverBackdrop extends StatelessWidget {
  const _CoverBackdrop();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final p = pal;
        final t = playerService.current;
        final art = t == null ? null : store.artFor(t);
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          child: Stack(key: ValueKey(art?.path ?? 'none'), fit: StackFit.expand, children: [
            Container(color: p.bg),
            if (art != null)
              // A 16-pixel copy stretched to the window looks like a heavy blur, for free.
              Opacity(
                opacity: p.dark ? 0.6 : 0.5,
                child: Image.file(art, fit: BoxFit.cover, cacheWidth: 16, filterQuality: FilterQuality.medium, gaplessPlayback: true),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.8, -0.9),
                    radius: 1.4,
                    colors: [kViolet.withValues(alpha: p.dark ? 0.45 : 0.18), p.bg],
                  ),
                ),
              ),
            Container(color: p.bg.withValues(alpha: p.dark ? 0.25 : 0.35)),
          ]),
        );
      },
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Glass(
        radius: 99,
        padding: const EdgeInsets.all(8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _RailBtn(Icons.grid_view_rounded, 'Home', DPage.home),
          const _RailBtn(Icons.search_rounded, 'Search the web', DPage.search),
          const _RailBtn(Icons.sync_rounded, 'Sync & downloads', DPage.sync),
          const _RailBtn(Icons.settings_outlined, 'Settings', DPage.settings),
          const SizedBox(height: 4),
          IconButton(
            tooltip: 'Light or dark',
            onPressed: () async {
              darkMode.value = !darkMode.value;
              store.darkTheme = darkMode.value;
              await store.save();
            },
            icon: Icon(pal.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
          ),
        ]),
      ),
    );
  }
}

class _RailBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final DPage page;
  const _RailBtn(this.icon, this.label, this.page);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DPage>(
      valueListenable: dPage,
      builder: (context, cur, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: IconButton(
          tooltip: label,
          style: IconButton.styleFrom(
            fixedSize: const Size(44, 44),
            backgroundColor: cur == page ? pal.text.withValues(alpha: 0.12) : Colors.transparent,
          ),
          onPressed: () => dPage.value = page,
          icon: Icon(icon, size: 20, color: pal.text),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, engine, dPage, dPlaylist]),
      builder: (context, _) {
        final p = pal;
        final lists = store.sortedPlaylists;
        final failed = (engine.lastReport?['counts'] as Map?)?['fail'] ?? 0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 22, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
              child: Row(children: [
                const SpotVaultMark(size: 30),
                const SizedBox(width: 10),
                Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'Spot', style: TextStyle(color: p.text)),
                      TextSpan(text: 'Vault', style: TextStyle(color: p.muted)),
                    ]),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
              ]),
            ),
            const _NavItem(Icons.home_outlined, 'Home', DPage.home),
            const _NavItem(Icons.music_note_outlined, 'Songs', DPage.songs),
            _NavItem(Icons.download_outlined, 'Sync & downloads', DPage.sync,
                badge: engine.syncing ? '${(engine.progress * 100).round()}%' : (failed is num && failed > 0 ? '$failed' : null)),
            const _NavItem(Icons.groups_outlined, 'Jam', DPage.jam),
            const _NavItem(Icons.tune_rounded, 'Studio', DPage.studio),
            const SizedBox(height: 14),
            Divider(color: p.line, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 0, 6),
              child: Row(children: [
                Expanded(child: Text('Your playlists', style: TextStyle(color: p.muted, fontSize: 13, fontWeight: FontWeight.w600))),
                IconButton(
                  tooltip: 'Add a playlist link',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => addPlaylistDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                ),
              ]),
            ),
            Expanded(
              child: lists.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text('Add a Spotify, YouTube or SoundCloud playlist link to start.', style: TextStyle(color: p.muted, fontSize: 12)),
                    )
                  : ListView.builder(
                      itemCount: lists.length,
                      itemBuilder: (context, i) {
                        final pl = lists[i];
                        final on = dPage.value == DPage.playlist && dPlaylist.value == pl.folder;
                        return _HoverTile(
                          selected: on,
                          onTap: () => openPlaylist(pl.folder),
                          child: Row(children: [
                            ArtImage(file: store.coverFor(pl), size: 36, radius: 8, fallback: Icons.queue_music_rounded),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(pl.name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 13, fontWeight: FontWeight.w500)),
                                Text('${pl.trackIds.length} songs', style: TextStyle(color: p.muted, fontSize: 11)),
                              ]),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final DPage page;
  final String? badge;
  const _NavItem(this.icon, this.label, this.page, {this.badge});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DPage>(
        // Listens itself: the items are const, so the sidebar rebuilding
        // doesn't rebuild them.
        valueListenable: dPage,
        builder: (context, cur, _) => _build(cur == page),
      );

  Widget _build(bool on) {
    final p = pal;
    return _HoverTile(
      selected: on,
      onTap: () => dPage.value = page,
      child: Row(children: [
        Icon(icon, size: 19, color: on ? p.text : p.muted),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(color: on ? p.text : p.muted, fontSize: 14, fontWeight: FontWeight.w500))),
        if (badge != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(99)),
            child: Text(badge!, style: TextStyle(color: p.dark ? Colors.black : Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}

class _HoverTile extends StatefulWidget {
  final Widget child;
  final bool selected;
  final VoidCallback onTap;
  const _HoverTile({required this.child, required this.onTap, this.selected = false});

  @override
  State<_HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<_HoverTile> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected ? p.text.withValues(alpha: 0.1) : (hover ? p.text.withValues(alpha: 0.05) : Colors.transparent),
            borderRadius: BorderRadius.circular(12),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Right column: now playing, a lyrics peek and what's next.
class _NowPanel extends StatelessWidget {
  const _NowPanel();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final p = pal;
        final t = playerService.current;
        final order = playerService.playOrder;
        final cur = playerService.player.currentIndex ?? 0;
        final pos = order.indexOf(cur);
        final seq = playerService.player.sequence;
        final next = <Track?>[
          if (pos >= 0)
            for (final i in order.skip(pos + 1).take(5))
              if (i < seq.length) playerService.trackById((seq[i].tag as dynamic).id as String),
        ].whereType<Track>().toList();
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: p.text.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.line),
            ),
            child: t == null
                ? Center(child: Text('Pick a song to play.', style: TextStyle(color: p.muted)))
                : ListView(children: [
                    Row(children: [
                      Icon(Icons.graphic_eq_rounded, size: 16, color: p.accent),
                      const SizedBox(width: 8),
                      Text('Now playing', style: TextStyle(color: p.muted, fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () => dPlayerOpen.value = true,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: AspectRatio(aspectRatio: 1, child: LayoutBuilder(builder: (c, b) => TrackArt(t, size: b.maxWidth, radius: 18))),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w600)),
                          Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 13)),
                        ]),
                      ),
                      IconButton(
                        tooltip: 'Like',
                        onPressed: () => store.toggleLike(t.id),
                        icon: Icon(store.favorites.contains(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: store.favorites.contains(t.id) ? kPink : p.muted),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    LyricsPeek(track: t),
                    const SizedBox(height: 10),
                    Divider(color: p.line),
                    Row(children: [
                      Expanded(child: Text('Up next', style: TextStyle(color: p.text, fontWeight: FontWeight.w600))),
                    ]),
                    const SizedBox(height: 6),
                    if (next.isEmpty) Text('Nothing after this song.', style: TextStyle(color: p.muted, fontSize: 12)),
                    for (final n in next)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(children: [
                          TrackArt(n, size: 38, radius: 8),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(n.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 13, fontWeight: FontWeight.w500)),
                              Text(n.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 12)),
                            ]),
                          ),
                        ]),
                      ),
                  ]),
          ),
        );
      },
    );
  }
}

/// The floating bar at the bottom: song, controls with a smooth timeline, volume.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Glass(
          radius: 22,
          frosted: true,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: ListenableBuilder(
            listenable: playerService,
            builder: (context, _) {
              final p = pal;
              final t = playerService.current;
              final pl = playerService.player;
              return Row(children: [
                SizedBox(
                  width: 250,
                  child: t == null
                      ? Text('Nothing playing', style: TextStyle(color: p.muted))
                      : InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => dPlayerOpen.value = true,
                          child: Row(children: [
                            TrackArt(t, size: 46, radius: 10),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                                Text(t.title,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w600, fontSize: 14)),
                                Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 12)),
                              ]),
                            ),
                          ]),
                        ),
                ),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(
                        tooltip: 'Shuffle',
                        onPressed: playerService.toggleShuffle,
                        icon: Icon(Icons.shuffle_rounded, size: 19, color: playerService.shuffleOn ? p.accent : p.text),
                      ),
                      IconButton(tooltip: 'Previous', onPressed: playerService.previous, icon: const Icon(Icons.skip_previous_rounded)),
                      const SizedBox(width: 4),
                      const PlayButton(size: 44),
                      const SizedBox(width: 4),
                      IconButton(tooltip: 'Next', onPressed: playerService.next, icon: const Icon(Icons.skip_next_rounded)),
                      IconButton(
                        tooltip: 'Repeat',
                        onPressed: playerService.cycleLoop,
                        icon: Icon(pl.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                            size: 19, color: pl.loopMode == LoopMode.off ? p.text : p.accent),
                      ),
                    ]),
                    const SizedBox(width: 560, child: SmoothTimeline(compact: true)),
                  ]),
                ),
                SizedBox(
                  width: 250,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    IconButton(tooltip: 'Lyrics', onPressed: () => dPlayerOpen.value = true, icon: const Icon(Icons.lyrics_outlined, size: 19)),
                    IconButton(tooltip: 'Jam', onPressed: () => dPage.value = DPage.jam, icon: const Icon(Icons.groups_outlined, size: 19)),
                    Icon(Icons.volume_up_rounded, size: 18, color: p.muted),
                    SizedBox(
                      width: 100,
                      child: StreamBuilder<double>(
                        stream: pl.volumeStream,
                        builder: (context, s) => SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                            overlayShape: SliderComponentShape.noOverlay,
                            activeTrackColor: p.text,
                            inactiveTrackColor: p.track,
                            thumbColor: p.text,
                          ),
                          child: Slider(value: (s.data ?? pl.volume).clamp(0, 1), onChanged: pl.setVolume),
                        ),
                      ),
                    ),
                  ]),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// Round play/pause button.
class PlayButton extends StatelessWidget {
  final double size;
  const PlayButton({super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return StreamBuilder<PlayerState>(
      stream: playerService.player.playerStateStream,
      builder: (context, s) {
        final playing = s.data?.playing ?? false;
        return Semantics(
          button: true,
          label: playing ? 'Pause' : 'Play',
          child: Material(
            color: isMinimal ? p.text : kViolet,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: playerService.togglePlay,
              child: SizedBox(
                width: size,
                height: size,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      key: ValueKey(playing), color: isMinimal ? p.bg : Colors.white, size: size * 0.5),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A timeline that glides every frame instead of jumping once a second.
class SmoothTimeline extends StatefulWidget {
  final bool compact;
  const SmoothTimeline({super.key, this.compact = false});

  @override
  State<SmoothTimeline> createState() => _SmoothTimelineState();
}

class _SmoothTimelineState extends State<SmoothTimeline> with SingleTickerProviderStateMixin {
  late final AnimationController _tick = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
  double? _drag;

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _tick,
      builder: (context, _) {
        final p = pal;
        final pl = playerService.player;
        final total = pl.duration ?? Duration.zero;
        final pos = pl.position;
        final ms = total.inMilliseconds;
        final v = _drag ?? (ms == 0 ? 0.0 : (pos.inMilliseconds / ms).clamp(0.0, 1.0));
        return Row(children: [
          SizedBox(
              width: 40,
              child: Text(fmtTime(Duration(milliseconds: (v * ms).round())),
                  textAlign: TextAlign.right, style: TextStyle(color: p.muted, fontSize: 11, fontFeatures: const [FontFeature.tabularFigures()]))),
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                left: 12,
                right: 12,
                child: WaveTint(
                  track: playerService.current,
                  builder: (context, color) => WaveProgress(
                      value: v.toDouble(), playing: pl.playing, color: color, baseline: 0.5, waveHeight: widget.compact ? 11 : 16, showLine: false),
                ),
              ),
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: widget.compact ? 4 : 5,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: widget.compact ? 6 : 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: p.text,
                  inactiveTrackColor: p.track,
                  thumbColor: kEmber,
                ),
                child: Slider(
                  value: v.toDouble(),
                  onChanged: ms == 0 ? null : (x) => setState(() => _drag = x),
                  onChangeEnd: (x) async {
                    await pl.seek(Duration(milliseconds: (x * ms).round()));
                    setState(() => _drag = null);
                  },
                ),
              ),
            ]),
          ),
          SizedBox(width: 40, child: Text(fmtTime(total), style: TextStyle(color: p.muted, fontSize: 11, fontFeatures: const [FontFeature.tabularFigures()]))),
        ]);
      },
    );
  }
}

/// Shows why the app can't work yet (downloader not started).
class _EngineBanner extends StatelessWidget {
  const _EngineBanner();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        if (engine.error.isEmpty) return const SizedBox();
        final p = pal;
        return Center(
          child: Center(
            child: Material(
              color: p.surface,
              elevation: 6,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error_outline_rounded, color: p.danger),
                  const SizedBox(width: 10),
                  ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: Text(engine.error, style: TextStyle(color: p.text))),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// True when this build runs as the Windows app.
bool get isDesktop => Platform.isWindows;
