import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../player_service.dart';
import 'aurora.dart';
import 'common.dart';

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
            body: Center(child: Text('Nothing playing', style: TextStyle(color: kMuted))),
          );
        }
        return Scaffold(
          body: AuroraBackground(
            intensity: 1.2,
            child: SafeArea(
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
                        const ThemeToggle(),
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
                          tooltip: p.shuffleModeEnabled ? 'Shuffle on' : 'Shuffle off',
                          iconSize: 24,
                          icon: Icon(Icons.shuffle_rounded, color: p.shuffleModeEnabled ? kAccent : kMuted),
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
                    const SizedBox(height: 12),
                  ],
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
      if (p.folder == t.folder) return p.title;
    }
    return t.folder;
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
                      transitionBuilder: (c, a) => RotationTransition(turns: Tween(begin: 0.75, end: 1.0).animate(a), child: ScaleTransition(scale: a, child: c)),
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
      ..shader = LinearGradient(colors: [playedTop, playedBottom], begin: Alignment.topCenter, end: Alignment.bottomCenter)
          .createShader(Offset.zero & size);
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
              icon: Icons.add_location_alt_rounded,
              label: 'Moment',
              isNew: true,
              active: false,
              onTap: () {
                final ok = store.addMoment(track.id, p.position.inMilliseconds);
                _toast(context, ok ? 'Moment saved at ${formatDuration(p.position)}' : 'There is already a Moment here');
              },
            ),
            _Tool(
              icon: Icons.all_inclusive_rounded,
              label: abLabel,
              isNew: true,
              active: ps.loopA != null,
              onTap: () {
                ps.tapAbLoop();
                if (ps.loopA != null && ps.loopB == null) _toast(context, 'Loop start set. Tap again where it should end.');
              },
              onLongPress: ps.loopA == null ? null : ps.clearAbLoop,
            ),
            _Tool(
              icon: Icons.bedtime_rounded,
              label: _sleepLabel(),
              active: ps.sleepMode != SleepMode.off,
              onTap: () => _sleepSheet(context),
            ),
            _Tool(
              icon: Icons.speed_rounded,
              label: '${p.speed.toStringAsFixed(p.speed % 1 == 0 ? 0 : 2)}×',
              active: p.speed != 1,
              onTap: () => _speedSheet(context),
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
                title: Row(children: [Text('Smart Sleep', style: TextStyle(color: kText)), const SizedBox(width: 8), const NewTag()]),
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

  void _speedSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Playback speed', style: displayStyle(18)),
            ),
            for (final s in [0.75, 1.0, 1.25, 1.5])
              ListTile(
                title: Text('$s×', style: TextStyle(color: kText)),
                trailing: playerService.player.speed == s ? Icon(Icons.check_rounded, color: kAccent) : null,
                onTap: () {
                  playerService.setSpeed(s);
                  Navigator.pop(ctx);
                },
              ),
          ],
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
  final bool isNew;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _Tool({required this.icon, required this.label, required this.active, required this.onTap, this.isNew = false, this.onLongPress});

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
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 62,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: active
                        ? LinearGradient(colors: [kViolet.withValues(alpha: 0.36), kEmber.withValues(alpha: 0.14)])
                        : null,
                    color: active ? null : (pal.dark ? pal.glass : pal.surface),
                    border: Border.all(color: active ? kViolet.withValues(alpha: 0.6) : kLine),
                  ),
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 20, color: active ? kText : kMuted),
                        const SizedBox(height: 4),
                        Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? kText : kMuted)),
                      ],
                    ),
                  ),
                ),
                if (isNew) const Positioned(top: -7, right: 4, child: NewTag()),
              ],
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
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(child: Text('Queue', style: displayStyle(20))),
                  Text('${seq.length} songs', style: TextStyle(color: kMuted)),
                ],
              ),
            ),
            if (p.shuffleModeEnabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Shuffle is on: songs play in random order', style: TextStyle(color: kMuted, fontSize: 12)),
              ),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: scroll,
                buildDefaultDragHandles: false,
                itemCount: seq.length,
                onReorderItem: (from, to) => playerService.move(from, to),
                itemBuilder: (_, i) {
                  final item = seq[i].tag as MediaItem;
                  final t = store.tracks[item.id];
                  final isCur = i == cur;
                  return Dismissible(
                    key: ValueKey('${item.id}-$i'),
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: isCur ? kAccent : kText, fontWeight: FontWeight.w600)),
                      subtitle: Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted)),
                      trailing: isCur
                          ? EqBars(color: kAccent, height: 14, bars: 3, playing: p.playing)
                          : ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle_rounded, color: kMuted)),
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
