import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app_state.dart';
import '../ui/wave_shape.dart';
import '../library_store.dart';
import '../lyrics_service.dart';
import '../player_service.dart' show SleepMode;
import '../ui/sound_sheet.dart';
import 'desktop_shell.dart';

/// Full-window player: wavy cover with a progress ring, controls, live lyrics.
class DesktopPlayer extends StatelessWidget {
  const DesktopPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([playerService, store]),
      builder: (context, _) {
        final p = pal;
        final t = playerService.current;
        final pl = playerService.player;
        final focus = store.playerLook == 'focus';
        return Material(
          color: p.bg.withValues(alpha: p.dark ? 0.72 : 0.78),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 26, 36, 36),
            child: Column(children: [
              Row(children: [
                IconButton.outlined(tooltip: 'Back', onPressed: () => dPlayerOpen.value = false, icon: const Icon(Icons.keyboard_arrow_down_rounded)),
                Expanded(
                  child: Column(children: [
                    Text('PLAYING', style: TextStyle(color: p.muted, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
                    Text(t == null ? '' : t.folder, style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                  ]),
                ),
                if (t != null)
                  IconButton.outlined(
                    tooltip: 'Like',
                    onPressed: () => store.toggleLike(t.id),
                    icon: Icon(store.isLiked(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: store.isLiked(t.id) ? kPink : p.text),
                  ),
              ]),
              const SizedBox(height: 10),
              Expanded(
                child: t == null
                    ? Center(child: Text('Pick a song to play.', style: TextStyle(color: p.muted)))
                    : focus
                        ? _FocusPlayer(track: t)
                        : Row(children: [
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420), child: AspectRatio(aspectRatio: 1, child: WavyCover(track: t)))),
                            const SizedBox(height: 26),
                            Text(t.title.toUpperCase(), textAlign: TextAlign.center, maxLines: 2, style: TextStyle(color: p.text, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                            const SizedBox(height: 6),
                            Text(t.subtitle, style: TextStyle(color: p.muted, fontSize: 15)),
                            const SizedBox(height: 18),
                            const SizedBox(width: 460, child: SmoothTimeline()),
                            const SizedBox(height: 6),
                            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              IconButton(onPressed: playerService.toggleShuffle, tooltip: 'Shuffle', icon: Icon(Icons.shuffle_rounded, color: playerService.shuffleOn ? p.accent : p.text)),
                              const SizedBox(width: 10),
                              IconButton(onPressed: playerService.previous, tooltip: 'Previous', iconSize: 30, icon: const Icon(Icons.skip_previous_rounded)),
                              const SizedBox(width: 14),
                              const PlayButton(size: 70),
                              const SizedBox(width: 14),
                              IconButton(onPressed: playerService.next, tooltip: 'Next', iconSize: 30, icon: const Icon(Icons.skip_next_rounded)),
                              const SizedBox(width: 10),
                              IconButton(
                                onPressed: playerService.cycleLoop,
                                tooltip: 'Repeat',
                                icon: Icon(pl.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded, color: pl.loopMode == LoopMode.off ? p.text : p.accent),
                              ),
                            ]),
                            const SizedBox(height: 16),
                            const _Tools(),
                          ]),
                        ),
                        const SizedBox(width: 36),
                        Expanded(child: _LyricsPanel(track: t)),
                      ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// Focus style: one centred column like the phone. The ring around the cover is
/// the timeline; the lyrics card at the bottom opens the full lyrics in place.
class _FocusPlayer extends StatefulWidget {
  final Track track;
  const _FocusPlayer({required this.track});

  @override
  State<_FocusPlayer> createState() => _FocusPlayerState();
}

class _FocusPlayerState extends State<_FocusPlayer> {
  bool lyrics = false;

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final t = widget.track;
    final pl = playerService.player;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(children: [
          StreamBuilder<Duration>(
            stream: pl.positionStream,
            builder: (context, s) => Text.rich(
              TextSpan(children: [
                TextSpan(text: _fmt(s.data ?? Duration.zero), style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                TextSpan(text: '  |  ${_fmt(pl.duration ?? Duration.zero)}', style: TextStyle(color: p.muted)),
              ]),
              style: const TextStyle(fontSize: 15, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: lyrics
                  ? _LyricsPanel(key: const ValueKey('lyrics'), track: t)
                  : Center(key: const ValueKey('cover'), child: AspectRatio(aspectRatio: 1, child: WavyCover(track: t))),
            ),
          ),
          const SizedBox(height: 14),
          Text(t.title.toUpperCase(), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
          const SizedBox(height: 4),
          Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 15)),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(
              onPressed: playerService.cycleLoop,
              tooltip: 'Repeat',
              icon: Icon(pl.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded, color: pl.loopMode == LoopMode.off ? p.text : p.accent),
            ),
            IconButton(onPressed: playerService.previous, tooltip: 'Previous', iconSize: 30, icon: const Icon(Icons.skip_previous_rounded)),
            const PlayButton(size: 72),
            IconButton(onPressed: playerService.next, tooltip: 'Next', iconSize: 30, icon: const Icon(Icons.skip_next_rounded)),
            IconButton(onPressed: playerService.toggleShuffle, tooltip: 'Shuffle', icon: Icon(Icons.shuffle_rounded, color: playerService.shuffleOn ? p.accent : p.text)),
          ]),
          const SizedBox(height: 14),
          Material(
            color: p.surface.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => setState(() => lyrics = !lyrics),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('Lyrics', style: TextStyle(color: p.text, fontWeight: FontWeight.w700))),
                    Icon(lyrics ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded, size: 16, color: p.muted),
                  ]),
                  const SizedBox(height: 6),
                  SizedBox(width: double.infinity, child: lyrics ? Text('Showing the lyrics above. Click to see the cover.', style: TextStyle(color: p.muted, fontSize: 13)) : LyricsPeek(track: t)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Queue, A-B, Sleep, Sound and Jam: all the same size and shape.
class _Tools extends StatelessWidget {
  const _Tools();

  @override
  Widget build(BuildContext context) {
    final ps = playerService;
    final sleeping = ps.sleepMode != SleepMode.off;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _Tool(Icons.queue_music_rounded, 'Queue', () => _queueSheet(context)),
      _Tool(Icons.repeat_on_rounded, ps.abActive ? 'A-B on' : (ps.loopA != null ? 'Set B' : 'A-B'), ps.tapAbLoop, on: ps.loopA != null),
      PopupMenuButton<int>(
        tooltip: 'Sleep timer',
        onSelected: (m) => ps.setSleepTimer(m == 0 ? null : Duration(minutes: m)),
        itemBuilder: (_) => [
          for (final m in [15, 30, 45, 60, 90]) PopupMenuItem(value: m, child: Text('$m minutes')),
          if (sleeping) const PopupMenuItem(value: 0, child: Text('Turn off')),
        ],
        child: _ToolFace(Icons.bedtime_outlined, sleeping ? 'Sleep on' : 'Sleep', on: sleeping),
      ),
      _Tool(Icons.tune_rounded, 'Sound', () => showSoundSheet(context)),
      _Tool(Icons.groups_outlined, 'Jam', () {
        dPlayerOpen.value = false;
        dPage.value = DPage.jam;
      }),
    ]);
  }
}

class _Tool extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool on;
  const _Tool(this.icon, this.label, this.onTap, {this.on = false});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: _ToolFace(icon, label, on: on)),
      );
}

class _ToolFace extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  const _ToolFace(this.icon, this.label, {this.on = false});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 64,
      height: 60,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: on ? p.accent.withValues(alpha: 0.16) : p.text.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: on ? p.accent : p.line),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 19, color: on ? p.accent : p.text),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: on ? p.accent : p.text)),
      ]),
    );
  }
}

void _queueSheet(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 460,
        height: 560,
        child: ListenableBuilder(
          listenable: playerService,
          builder: (context, _) {
            final p = pal;
            final order = playerService.playOrder;
            final seq = playerService.player.sequence;
            final cur = playerService.player.currentIndex ?? 0;
            final start = math.max(0, order.indexOf(cur));
            final items = [
              for (final i in order.skip(start))
                if (i < seq.length) (i, playerService.trackById((seq[i].tag as dynamic).id as String)),
            ];
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.fromLTRB(22, 20, 22, 8), child: Text('Queue', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w700))),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, k) {
                    final (i, t) = items[k];
                    if (t == null) return const SizedBox();
                    return ListTile(
                      selected: i == cur,
                      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => playerService.jumpTo(i),
                      trailing: i == cur
                          ? Icon(Icons.graphic_eq_rounded, color: p.accent)
                          : IconButton(tooltip: 'Remove', onPressed: () => playerService.removeAt(i), icon: const Icon(Icons.close_rounded, size: 18)),
                    );
                  },
                ),
              ),
            ]);
          },
        ),
      ),
    ),
  );
}

/// The cover in a soft wavy shape, with a thin ring that fills as the song plays.
class WavyCover extends StatefulWidget {
  final Track track;
  final double inset;
  const WavyCover({super.key, required this.track, this.inset = 30});

  @override
  State<WavyCover> createState() => _WavyCoverState();
}

class _WavyCoverState extends State<WavyCover> with SingleTickerProviderStateMixin {
  late final AnimationController _tick = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final art = store.artFor(widget.track);
    return AnimatedBuilder(
      animation: _tick,
      builder: (context, _) {
        final pl = playerService.player;
        final ms = pl.duration?.inMilliseconds ?? 0;
        final v = ms == 0 ? 0.0 : (pl.position.inMilliseconds / ms).clamp(0.0, 1.0);
        return CustomPaint(
          foregroundPainter: _RingPainter(v, p.text, p.line, kEmber),
          child: Padding(
            padding: EdgeInsets.all(widget.inset),
            child: ClipPath(
              clipper: const WaveClipper(),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: art == null
                    ? Container(key: const ValueKey('none'), decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF7A1A19), Color(0xFF1A1A1C)], begin: Alignment.topLeft, end: Alignment.bottomRight)))
                    : Image.file(art, key: ValueKey(art.path), fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final double v;
  final Color fg, bg, dot;
  _RingPainter(this.v, this.fg, this.bg, this.dot);

  @override
  void paint(Canvas canvas, Size size) {
    final path = wavePath(size, 8);
    canvas.drawPath(path, Paint()..color = bg..style = PaintingStyle.stroke..strokeWidth = 2);
    final metric = path.computeMetrics().first;
    final len = metric.length * v;
    canvas.drawPath(metric.extractPath(0, len), Paint()..color = fg..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round);
    final tan = metric.getTangentForOffset(len);
    if (tan != null) canvas.drawCircle(tan.position, 7, Paint()..color = dot);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.fg != fg;
}

/// Big live lyrics: the line being sung lights up and stays in view. Click a line to jump there.
class _LyricsPanel extends StatefulWidget {
  final Track track;
  const _LyricsPanel({super.key, required this.track});

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  Future<Lyrics>? _future;
  String _for = '';
  final _scroll = ScrollController();
  final List<GlobalKey> _keys = [];
  int _last = -2;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    if (_for != widget.track.id) {
      _for = widget.track.id;
      _future = lyricsService.get(widget.track);
      _last = -2;
    }
    return Glass(
      radius: 28,
      opacity: 0.8,
      padding: const EdgeInsets.fromLTRB(34, 28, 34, 28),
      child: FutureBuilder<Lyrics>(
        future: _future,
        builder: (context, snap) {
          final l = snap.data;
          Widget body;
          if (snap.connectionState != ConnectionState.done) {
            body = Center(child: CircularProgressIndicator(color: p.accent));
          } else if (l == null || l.isEmpty) {
            body = Center(child: Text(snap.hasError && isOffline(snap.error!) ? 'Lyrics need the internet the first time.' : 'No lyrics found for this song.', style: TextStyle(color: p.muted)));
          } else if (!l.synced) {
            body = SingleChildScrollView(child: Text(l.plain, style: TextStyle(color: p.text, fontSize: 22, height: 1.6, fontWeight: FontWeight.w600)));
          } else {
            while (_keys.length < l.lines.length) {
              _keys.add(GlobalKey());
            }
            body = StreamBuilder<Duration>(
              stream: playerService.player.positionStream,
              builder: (context, s) {
                final idx = l.indexAt((s.data ?? Duration.zero) + const Duration(milliseconds: 250));
                if (idx != _last) {
                  _last = idx;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final ctx = idx >= 0 ? _keys[idx].currentContext : null;
                    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
                  });
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 160),
                  itemCount: l.lines.length,
                  itemBuilder: (context, i) {
                    final line = l.lines[i];
                    return InkWell(
                      key: _keys[i],
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => playerService.player.seek(line.at),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                          style: TextStyle(
                            fontSize: i == idx ? 32 : 26,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                            color: i == idx ? p.text : p.text.withValues(alpha: i < idx ? 0.3 : 0.48),
                          ),
                          child: Text(line.text.isEmpty ? '♪' : line.text),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('LYRICS', style: TextStyle(color: p.muted, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
              const Spacer(),
              if (l != null && l.synced) Text('Click a line to jump there', style: TextStyle(color: p.muted, fontSize: 12)),
            ]),
            const SizedBox(height: 10),
            Expanded(child: body),
          ]);
        },
      ),
    );
  }
}

/// Two lines of lyrics under the cover in the Now playing panel.
class LyricsPeek extends StatelessWidget {
  final Track track;
  const LyricsPeek({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return FutureBuilder<Lyrics?>(
      future: lyricsService.get(track),
      builder: (context, snap) {
        final l = snap.data;
        if (l == null || l.isEmpty) return const SizedBox();
        if (!l.synced) {
          return Text(l.plain.split('\n').where((s) => s.trim().isNotEmpty).take(2).join('\n'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 13, height: 1.5));
        }
        return StreamBuilder<Duration>(
          stream: playerService.player.positionStream,
          builder: (context, s) {
            final i = l.indexAt(s.data ?? Duration.zero);
            final now = i >= 0 ? l.lines[i].text : '';
            final next = i + 1 < l.lines.length ? l.lines[i + 1].text : '';
            return InkWell(
              onTap: () => dPlayerOpen.value = true,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: now.isEmpty ? '♪ ' : '$now\n', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                  TextSpan(text: next, style: TextStyle(color: p.muted)),
                ]),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            );
          },
        );
      },
    );
  }
}
