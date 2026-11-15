import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;

import '../desktop/desktop_player.dart' show WavyCover;
import '../app_state.dart';
import '../library_store.dart';
import '../player_service.dart';
import 'aurora.dart';
import 'common.dart';
import 'wave_progress.dart';
import 'lyrics_screen.dart';
import 'nearby_ui.dart';
import 'sound_sheet.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([playerService, store]),
      builder: (context, _) {
        final t = playerService.current;
        final p = playerService.player;
        if (t == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Nothing playing', style: TextStyle(color: kMuted)),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: () => openJam(context), icon: const Icon(Icons.groups_rounded), label: const Text('Jam with friends')),
              ]),
            ),
          );
        }
        lyricsService.prefetch(t);
        // The Minimal look has its own player (2.0 design); Crimson keeps the classic one.
        if (isMinimal) return _MinimalPlayer(track: t, playlistName: _playlistName(t));
        return Scaffold(
          body: AuroraBackground(
            intensity: 1.2,
            child: SafeArea(
              child: GestureDetector(
                // Swipe up anywhere for lyrics.
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < -400) openLyrics(context);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Column(
                    children: [
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          GlassIconButton(
                            icon: Icons.keyboard_arrow_down_rounded,
                            tooltip: 'Close',
                            onPressed: () => Navigator.pop(context),
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Text('PLAYING FROM', style: TextStyle(fontSize: 10.5, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: kMuted)),
                                const SizedBox(height: 2),
                                Text(_playlistName(t),
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: kText)),
                              ],
                            ),
                          ),
                          GlassIconButton(icon: Icons.groups_rounded, tooltip: 'Jam', onPressed: () => openJam(context)),
                          const SizedBox(width: 8),
                          GlassIconButton(icon: Icons.more_horiz_rounded, tooltip: 'Song options', onPressed: () => showTrackMenu(context, t)),
                        ],
                      ),
                      const Spacer(),
                      GestureDetector(
                        onHorizontalDragEnd: (d) {
                          final v = d.primaryVelocity ?? 0;
                          if (v < -300) playerService.next();
                          if (v > 300) playerService.previous();
                        },
                        onDoubleTap: () => store.toggleLike(t.id),
                        child: LayoutBuilder(
                          builder: (_, c) {
                            final maxH = MediaQuery.sizeOf(context).height * 0.38;
                            final side = math.min(c.maxWidth - 24, maxH);
                            return _GlowingArt(track: t, side: side, playing: p.playing);
                          },
                        ),
                      ),
                      const Spacer(),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              transitionBuilder: (child, a) => FadeTransition(
                                opacity: a,
                                child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
                              ),
                              child: Column(
                                key: ValueKey(t.id),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: displayStyle(24)),
                                  const SizedBox(height: 4),
                                  Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: kMuted)),
                                ],
                              ),
                            ),
                          ),
                          _LikeButton(liked: store.isLiked(t.id), onTap: () => store.toggleLike(t.id)),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _WaveSeek(track: t),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            tooltip: playerService.shuffleOn ? 'Shuffle on' : 'Shuffle off',
                            iconSize: 24,
                            icon: Icon(Icons.shuffle_rounded, color: playerService.shuffleOn ? kAccent : kMuted),
                            onPressed: playerService.toggleShuffle,
                          ),
                          IconButton(
                            tooltip: 'Previous',
                            iconSize: 38,
                            icon: Icon(Icons.skip_previous_rounded, color: kText),
                            onPressed: playerService.previous,
                          ),
                          _PlayButton(player: p),
                          IconButton(
                            tooltip: 'Next',
                            iconSize: 38,
                            icon: Icon(Icons.skip_next_rounded, color: kText),
                            onPressed: playerService.next,
                          ),
                          IconButton(
                            tooltip: switch (p.loopMode) { LoopMode.off => 'Repeat off', LoopMode.all => 'Repeat all', LoopMode.one => 'Repeat one' },
                            iconSize: 24,
                            icon: Icon(
                              p.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                              color: p.loopMode == LoopMode.off ? kMuted : kAccent,
                            ),
                            onPressed: playerService.cycleLoop,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _ToolRow(track: t),
                      const SizedBox(height: 6),
                      Semantics(
                        button: true,
                        label: 'Show lyrics',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => openLyrics(context),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.keyboard_arrow_up_rounded, color: kMuted, size: 20),
                              Text('Lyrics', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kMuted)),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _playlistName(Track t) {
    for (final p in store.playlists) {
      if (p.folder == t.folder) return p.name;
    }
    return t.folder;
  }
}

// ---------------------------------------------------------------------------
// Minimal player (2.0 design): round outline buttons, the time above a wavy
// cover with a progress ring, a big title, a black play button, the tools and
// a lyrics card peeking from the bottom.
// ---------------------------------------------------------------------------
class _MinimalPlayer extends StatelessWidget {
  final Track track;
  final String playlistName;
  const _MinimalPlayer({required this.track, required this.playlistName});

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final t = track;
    final player = playerService.player;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -400) openLyrics(context);
            if ((d.primaryVelocity ?? 0) > 500) Navigator.pop(context);
          },
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(children: [
                _OutlineIcon(icon: Icons.keyboard_arrow_down_rounded, label: 'Close', onTap: () => Navigator.pop(context)),
                Expanded(
                  child: Column(children: [
                    Text('Now playing', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.text)),
                    Text(playlistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: p.muted)),
                  ]),
                ),
                _OutlineIcon(
                  icon: store.isLiked(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: store.isLiked(t.id) ? const Color(0xFFE0403B) : null,
                  label: store.isLiked(t.id) ? 'Remove from Liked Songs' : 'Add to Liked Songs',
                  onTap: () => store.toggleLike(t.id),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (context, s) => Text.rich(
                TextSpan(children: [
                  TextSpan(text: _fmt(s.data ?? Duration.zero), style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                  TextSpan(text: '  |  ${_fmt(player.duration ?? t.length)}', style: TextStyle(color: p.muted)),
                ]),
                style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            Expanded(
              child: Center(
                child: LayoutBuilder(builder: (context, c) {
                  final side = math.min(c.maxWidth - 40, c.maxHeight - 8).clamp(180.0, 380.0);
                  return GestureDetector(
                    onHorizontalDragEnd: (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v < -300) playerService.next();
                      if (v > 300) playerService.previous();
                    },
                    onDoubleTap: () => store.toggleLike(t.id),
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: Hero(
                        tag: 'art',
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 450),
                          transitionBuilder: (c, a) =>
                              FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: c)),
                          child: WavyCover(key: ValueKey(t.id), track: t, inset: 18),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Column(key: ValueKey(t.id), children: [
                  Text(t.title.toUpperCase(),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 0.6, height: 1.15, color: p.text)),
                  const SizedBox(height: 5),
                  Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: p.muted)),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: _SlimSeek(player: player)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                IconButton(
                  tooltip: switch (player.loopMode) { LoopMode.off => 'Repeat off', LoopMode.all => 'Repeat all', LoopMode.one => 'Repeat one' },
                  icon: Icon(player.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                      color: player.loopMode == LoopMode.off ? p.text : const Color(0xFFE0403B)),
                  onPressed: playerService.cycleLoop,
                ),
                IconButton(tooltip: 'Previous', iconSize: 30, icon: Icon(Icons.skip_previous_rounded, color: p.text), onPressed: playerService.previous),
                StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (context, s) {
                    final playing = s.data?.playing ?? false;
                    return Semantics(
                      button: true,
                      label: playing ? 'Pause' : 'Play',
                      child: Pressable(
                        onTap: playerService.togglePlay,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                            child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing), color: p.bg, size: 32),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                IconButton(tooltip: 'Next', iconSize: 30, icon: Icon(Icons.skip_next_rounded, color: p.text), onPressed: playerService.next),
                IconButton(
                  tooltip: playerService.shuffleOn ? 'Shuffle on' : 'Shuffle off',
                  icon: Icon(Icons.shuffle_rounded, color: playerService.shuffleOn ? const Color(0xFFE0403B) : p.text),
                  onPressed: playerService.toggleShuffle,
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: _ToolRow(track: t)),
            const SizedBox(height: 12),
            _LyricsPeek(track: t),
          ]),
        ),
      ),
    );
  }
}

class _OutlineIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  const _OutlineIcon({required this.icon, required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: Pressable(
            onTap: onTap,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: pal.line)),
              child: Icon(icon, size: 20, color: color ?? pal.text),
            ),
          ),
        ),
      );
}

/// A thin timeline under the title (the ring around the cover shows it too).
class _SlimSeek extends StatefulWidget {
  final AudioPlayer player;
  const _SlimSeek({required this.player});

  @override
  State<_SlimSeek> createState() => _SlimSeekState();
}

class _SlimSeekState extends State<_SlimSeek> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, s) {
        final total = widget.player.duration?.inMilliseconds ?? 0;
        final v = _drag ?? (total == 0 ? 0.0 : ((s.data?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0));
        return Stack(children: [
          // The moving wave above the played part (the slider draws the line).
          Positioned.fill(
            left: 14,
            right: 14,
            child: WaveTint(
              track: playerService.current,
              builder: (context, color) => WaveProgress(value: v, playing: widget.player.playing, color: color, baseline: 0.5, waveHeight: 18, showLine: false),
            ),
          ),
          _slider(p, v, total),
        ]);
      },
    );
  }

  Widget _slider(Palette p, double v, int total) {
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: p.text,
        inactiveTrackColor: p.track,
        thumbColor: const Color(0xFFE0403B),
      ),
      child: Slider(
        value: v.toDouble(),
        onChanged: total == 0 ? null : (x) => setState(() => _drag = x),
        onChangeEnd: (x) async {
          await widget.player.seek(Duration(milliseconds: (x * total).round()));
          if (mounted) setState(() => _drag = null);
        },
      ),
    );
  }
}

/// The lyrics card that peeks from the bottom; tap or swipe up for full lyrics.
class _LyricsPeek extends StatelessWidget {
  final Track track;
  const _LyricsPeek({required this.track});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Semantics(
      button: true,
      label: 'Show lyrics',
      child: GestureDetector(
        onTap: () => openLyrics(context),
        child: Container(
          width: double.infinity,
          height: 104 + MediaQuery.paddingOf(context).bottom,
          padding: EdgeInsets.fromLTRB(22, 14, 14, MediaQuery.paddingOf(context).bottom),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: p.dark ? 0.3 : 0.06), blurRadius: 24, offset: const Offset(0, -6))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Lyrics', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.text))),
              Icon(Icons.open_in_full_rounded, size: 16, color: p.muted),
              const SizedBox(width: 6),
            ]),
            const SizedBox(height: 6),
            FutureBuilder(
              future: lyricsService.cached(track),
              builder: (context, snap) {
                final l = snap.data;
                if (l == null || l.isEmpty) {
                  return Text('Tap to see the lyrics', style: TextStyle(color: p.muted, fontSize: 14));
                }
                if (!l.synced) {
                  return Text(l.plain.split('\n').where((x) => x.trim().isNotEmpty).take(2).join(' '),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 14, height: 1.4));
                }
                return StreamBuilder<Duration>(
                  stream: playerService.player.positionStream,
                  builder: (context, s) {
                    final i = l.indexAt(s.data ?? Duration.zero);
                    final now = i >= 0 ? l.lines[i].text : '';
                    final next = i + 1 < l.lines.length ? l.lines[i + 1].text : '';
                    return Text.rich(
                      TextSpan(children: [
                        TextSpan(text: now.isEmpty ? '♪  ' : '$now  ', style: TextStyle(color: p.text, fontWeight: FontWeight.w700)),
                        TextSpan(text: next, style: TextStyle(color: p.muted)),
                      ]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, height: 1.4),
                    );
                  },
                );
              },
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Artwork with a breathing glow and a light ring that orbits while playing.
// ---------------------------------------------------------------------------
class _GlowingArt extends StatefulWidget {
  final Track track;
  final double side;
  final bool playing;
  const _GlowingArt({required this.track, required this.side, required this.playing});

  @override
  State<_GlowingArt> createState() => _GlowingArtState();
}

class _GlowingArtState extends State<_GlowingArt> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 5));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _spin.repeat();
  }

  @override
  void didUpdateWidget(_GlowingArt old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_spin.isAnimating) _spin.repeat();
    if (!widget.playing && _spin.isAnimating) _spin.stop();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.side;
    if (isMinimal) {
      // Minimal look: the cover in a soft wavy shape with a progress ring around it.
      return SizedBox(
        width: s + 24,
        height: s + 24,
        child: Hero(tag: 'art', child: WavyCover(track: widget.track, inset: 22)),
      );
    }
    return SizedBox(
      width: s + 24,
      height: s + 24,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (_, child) {
          final breathe = 0.5 + 0.5 * math.sin(_spin.value * 2 * math.pi);
          return Stack(
            alignment: Alignment.center,
            children: [
              // Glow
              Container(
                width: s * 0.9,
                height: s * 0.9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: kViolet.withValues(alpha: (pal.dark ? 0.45 : 0.30) + 0.12 * breathe),
                      blurRadius: 70 + 20 * breathe,
                      spreadRadius: 6,
                    ),
                    BoxShadow(color: kForest.withValues(alpha: pal.dark ? 0.35 : 0.18), blurRadius: 90, offset: const Offset(30, 30)),
                  ],
                ),
              ),
              // Orbiting ring
              Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: CustomPaint(size: Size(s + 20, s + 20), painter: _RingPainter(visible: widget.playing)),
              ),
              child!,
            ],
          );
        },
        child: AnimatedScale(
          scale: widget.playing ? 1 : 0.92,
          duration: const Duration(milliseconds: 600),
          curve: const Cubic(0.2, 0.8, 0.2, 1),
          child: Hero(
            tag: 'art',
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (c, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(a), child: c)),
              child: TrackArt(widget.track, key: ValueKey(widget.track.id), size: s, radius: 30),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final bool visible;
  _RingPainter({required this.visible});

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(1.5), const Radius.circular(36));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..shader = const SweepGradient(
        colors: [Colors.transparent, Colors.transparent, kEmber, kViolet, Colors.transparent],
        stops: [0, 0.55, 0.75, 0.9, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.visible != visible;
}

class _LikeButton extends StatelessWidget {
  final bool liked;
  final VoidCallback onTap;
  const _LikeButton({required this.liked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: liked ? 'Remove from Liked Songs' : 'Add to Liked Songs',
      child: Pressable(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pal.dark ? pal.glass : pal.surface,
            border: Border.all(color: kLine),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.elasticOut), child: c),
            child: Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(liked),
              color: liked ? kPink : kMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final AudioPlayer player;
  const _PlayButton({required this.player});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (_, snap) {
        final playing = snap.data?.playing ?? player.playing;
        final buffering = snap.data?.processingState == ProcessingState.loading;
        return Pressable(
          onTap: playerService.togglePlay,
          child: Semantics(
            button: true,
            label: playing ? 'Pause' : 'Play',
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [kEmber, kViolet], begin: Alignment.topLeft, end: Alignment.bottomRight),
                boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.55), blurRadius: 30, offset: const Offset(0, 12))],
              ),
              child: buffering
                  ? const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (c, a) =>
                          RotationTransition(turns: Tween(begin: 0.75, end: 1.0).animate(a), child: ScaleTransition(scale: a, child: c)),
                      child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing), size: 40, color: Colors.white),
                    ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Waveform seek bar with Moment pins and the A-B Loop range.
// ---------------------------------------------------------------------------
class _WaveSeek extends StatefulWidget {
  final Track track;
  const _WaveSeek({required this.track});

  @override
  State<_WaveSeek> createState() => _WaveSeekState();
}

class _WaveSeekState extends State<_WaveSeek> with SingleTickerProviderStateMixin {
  double? dragging; // 0..1
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// Bar shape for this song: the same every time, different per song.
  List<double> _shape(int n) {
    final r = math.Random(widget.track.id.hashCode);
    var prev = 0.5;
    return List.generate(n, (i) {
      final edge = math.min(i, n - 1 - i) / (n * 0.12);
      prev = (prev * 0.45 + r.nextDouble() * 0.55).clamp(0.15, 1.0);
      return prev * math.min(1.0, 0.35 + edge);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = playerService.player;
    return StreamBuilder<Duration>(
      stream: p.positionStream,
      builder: (context, snap) {
        final total = p.duration ?? widget.track.length;
        final totalMs = math.max(1, total.inMilliseconds);
        final pos = snap.data ?? Duration.zero;
        final f = dragging ?? (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
        final shown = Duration(milliseconds: (f * totalMs).round());
        final moments = store.momentsOf(widget.track.id);
        final a = playerService.loopA, b = playerService.loopB;

        return LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          final n = (w / 7).floor();
          final shape = _shape(n);
          void seekTo(double x) => setState(() => dragging = (x / w).clamp(0.0, 1.0));
          void commit() {
            final d = dragging;
            if (d != null) p.seek(Duration(milliseconds: (d * totalMs).round()));
            setState(() => dragging = null);
          }

          return Column(
            children: [
              Semantics(
                slider: true,
                label: 'Seek',
                value: '${formatDuration(shown)} of ${formatDuration(total)}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => seekTo(d.localPosition.dx),
                  onTapUp: (_) => commit(),
                  onHorizontalDragStart: (d) => seekTo(d.localPosition.dx),
                  onHorizontalDragUpdate: (d) => seekTo(d.localPosition.dx),
                  onHorizontalDragEnd: (_) => commit(),
                  child: SizedBox(
                    height: 70,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (a != null)
                          Positioned(
                            left: w * (a.inMilliseconds / totalMs).clamp(0.0, 1.0),
                            width: b == null ? 2 : w * ((b - a).inMilliseconds / totalMs).clamp(0.0, 1.0),
                            top: 12,
                            bottom: 0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: kCyan.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                                border: const Border.symmetric(vertical: BorderSide(color: kCyan, width: 2)),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          top: 14,
                          child: RepaintBoundary(
                            child: AnimatedBuilder(
                              animation: _pulse,
                              builder: (_, __) => CustomPaint(
                                painter: _WavePainter(
                                  shape: shape,
                                  progress: f,
                                  phase: p.playing ? _pulse.value : 0,
                                  rest: pal.track,
                                  playedTop: kEmber,
                                  playedBottom: pal.accent,
                                ),
                              ),
                            ),
                          ),
                        ),
                        for (final m in moments)
                          Positioned(
                            left: w * (m / totalMs).clamp(0.0, 1.0) - 14,
                            top: -10,
                            child: Tooltip(
                              message: 'Moment at ${formatDuration(Duration(milliseconds: m))}. Long-press to remove',
                              child: GestureDetector(
                                onTap: () => p.seek(Duration(milliseconds: m)),
                                onLongPress: () => store.removeMoment(widget.track.id, m),
                                child: const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: Icon(Icons.location_on_rounded, color: kPink, size: 20),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(shown), style: TextStyle(color: kMuted, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()])),
                  Text(formatDuration(total), style: TextStyle(color: kMuted, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
            ],
          );
        });
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> shape;
  final double progress;
  final double phase;
  final Color rest, playedTop, playedBottom;
  _WavePainter({
    required this.shape,
    required this.progress,
    required this.phase,
    required this.rest,
    required this.playedTop,
    required this.playedBottom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = shape.length;
    if (n == 0) return;
    final step = size.width / n;
    final barW = step * 0.55;
    final played = Paint()
      ..shader = LinearGradient(colors: [playedTop, playedBottom], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(Offset.zero & size);
    final idle = Paint()..color = rest;
    final cy = size.height / 2;
    for (var i = 0; i < n; i++) {
      final x = i * step + (step - barW) / 2;
      final isPlayed = (i + 0.5) / n <= progress;
      // Played bars sway a little while music plays.
      final sway = isPlayed ? 0.88 + 0.12 * math.sin(phase * 2 * math.pi + i * 0.6) : 1.0;
      final h = math.max(3.0, shape[i] * size.height * sway);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, cy - h / 2, barW, h), Radius.circular(barW / 2)),
        isPlayed ? played : idle,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress || old.phase != phase || old.shape != shape || old.rest != rest || old.playedBottom != playedBottom;
}

// ---------------------------------------------------------------------------
// Moment, A-B Loop, Smart Sleep, speed and queue.
// ---------------------------------------------------------------------------
class _ToolRow extends StatelessWidget {
  final Track track;
  const _ToolRow({required this.track});

  @override
  Widget build(BuildContext context) {
    final ps = playerService;
    final p = ps.player;
    final abLabel = ps.abActive ? 'Looping' : (ps.loopA != null ? 'Set B' : 'A–B');
    return Column(
      children: [
        Row(
          children: [
            _Tool(
              icon: Icons.bookmark_add_outlined,
              label: 'Moment',
              active: false,
              onTap: () {
                final ok = store.addMoment(track.id, p.position.inMilliseconds);
                _toast(context, ok ? 'Moment saved at ${formatDuration(p.position)}' : 'There is already a Moment here');
              },
            ),
            _Tool(
              icon: Icons.repeat_rounded,
              label: abLabel,
              active: ps.loopA != null,
              onTap: () {
                ps.tapAbLoop();
                if (ps.loopA != null && ps.loopB == null) _toast(context, 'Loop start set. Tap again where it should end.');
              },
              onLongPress: ps.loopA == null ? null : ps.clearAbLoop,
            ),
            _Tool(
              icon: Icons.bedtime_outlined,
              label: _sleepLabel(),
              active: ps.sleepMode != SleepMode.off,
              onTap: () => _sleepSheet(context),
            ),
            _Tool(
              icon: Icons.tune_rounded,
              label: p.speed != 1 ? '${p.speed.toStringAsFixed(p.speed % 1 == 0 ? 0 : 2)}×' : 'Sound',
              active: p.speed != 1 || store.crossfadeSec > 0 || store.eqPreset != 'off',
              onTap: () => showSoundSheet(context),
            ),
            _Tool(
              icon: Icons.queue_music_rounded,
              label: 'Queue',
              active: false,
              onTap: () => _queueSheet(context),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: ps.abActive
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Repeating ${formatDuration(ps.loopA!)}–${formatDuration(ps.loopB!)} · tap Looping to stop',
                    style: TextStyle(fontSize: 12, color: kMuted),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  String _sleepLabel() {
    switch (playerService.sleepMode) {
      case SleepMode.off:
        return 'Sleep';
      case SleepMode.endOfTrack:
        return 'Song end';
      case SleepMode.timer:
        final left = playerService.sleepAt!.difference(DateTime.now());
        return '${left.inMinutes + 1} min';
    }
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  void _sleepSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (_, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Sleep timer', style: displayStyle(18)),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final m in [5, 15, 30, 45, 60])
                    ActionChip(
                      label: Text('$m min'),
                      onPressed: () {
                        playerService.setSleepTimer(Duration(minutes: m));
                        Navigator.pop(ctx);
                      },
                    ),
                  ActionChip(
                    label: const Text('End of song'),
                    onPressed: () {
                      playerService.sleepAtEndOfTrack();
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: store.smartSleep,
                onChanged: (v) {
                  store.smartSleep = v;
                  store.changed();
                },
                title: Text('Smart Sleep', style: TextStyle(color: kText)),
                subtitle: Text('Fades the music out slowly instead of stopping suddenly', style: TextStyle(color: kMuted, fontSize: 12)),
              ),
              if (playerService.sleepMode != SleepMode.off)
                ListTile(
                  title: const Text('Turn off timer', style: TextStyle(color: kDanger)),
                  onTap: () {
                    playerService.setSleepTimer(null);
                    Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _queueSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (_, scroll) => _QueueList(scroll),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _Tool({required this.icon, required this.label, required this.active, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Semantics(
          button: true,
          label: label,
          child: Pressable(
            onTap: onTap,
            onLongPress: onLongPress,
            // Every tool is the same size and shape; "on" only changes the colours.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: active ? kAccent.withValues(alpha: 0.14) : (pal.dark ? pal.glass : pal.surface),
                border: Border.all(color: active ? kAccent.withValues(alpha: 0.7) : kLine),
              ),
              child: ExcludeSemantics(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 21, color: active ? kAccent : kText),
                    const SizedBox(height: 5),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? kAccent : kMuted)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueList extends StatelessWidget {
  final ScrollController scroll;
  const _QueueList(this.scroll);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final p = playerService.player;
        final seq = p.sequence;
        final cur = p.currentIndex ?? 0;
        // The queue starts at the song playing now and lists what plays next,
        // in the order it will really play (songs already played are hidden).
        final order = playerService.playOrder;
        final start = order.contains(cur) ? order.indexOf(cur) : 0;
        final shown = order.sublist(start);
        final canDrag = !playerService.shuffleOn;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(child: Text('Queue', style: displayStyle(20))),
                  Text('${shown.length - 1} up next', style: TextStyle(color: kMuted)),
                ],
              ),
            ),
            if (playerService.shuffleOn)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Shuffle is on: songs play in random order', style: TextStyle(color: kMuted, fontSize: 12)),
              ),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: scroll,
                buildDefaultDragHandles: false,
                itemCount: shown.length,
                // Shuffle off: the shown list is the sequence from the current song on.
                onReorderItem: (from, to) {
                  if (canDrag && from > 0 && to > 0) playerService.move(start + from, start + to);
                },
                itemBuilder: (_, pos) {
                  final i = shown[pos];
                  final item = seq[i].tag as MediaItem;
                  final t = store.tracks[item.id];
                  final isCur = i == cur;
                  return Dismissible(
                    key: ValueKey('${item.id}-$i-$pos'),
                    direction: isCur ? DismissDirection.none : DismissDirection.endToStart,
                    background: Container(
                      color: kDanger.withValues(alpha: 0.85),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete_rounded, color: Colors.white),
                    ),
                    onDismissed: (_) => playerService.removeAt(i),
                    child: ListTile(
                      leading: t == null ? Icon(Icons.music_note, color: kMuted) : TrackArt(t, size: 42),
                      title: Text(item.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isCur ? kAccent : kText, fontWeight: FontWeight.w600)),
                      subtitle: Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted)),
                      trailing: isCur
                          ? EqBars(color: kAccent, height: 14, bars: 3, playing: p.playing)
                          : canDrag
                              ? ReorderableDragStartListener(index: pos, child: Icon(Icons.drag_handle_rounded, color: kMuted))
                              : null,
                      onTap: () => playerService.jumpTo(i),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
