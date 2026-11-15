import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';

/// Crimson red used when the look is Crimson or the cover has no clear colour.
const kWaveRed = Color(0xFFE0403B);

final Map<String, Color?> _tintCache = {};

/// The main colour of a song's cover (bright enough to show on dark and
/// light), or null when there is no cover. Cached per file.
Future<Color?> coverTint(File? file) async {
  if (file == null) return null;
  final key = file.path;
  if (_tintCache.containsKey(key)) return _tintCache[key];
  Color? out;
  try {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 16, targetHeight: 16);
    final img = (await codec.getNextFrame()).image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data != null) {
      // Average the most colourful pixels, so a grey background doesn't win.
      final px = <HSVColor>[];
      for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
        px.add(HSVColor.fromColor(Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2))));
      }
      px.sort((a, b) => (b.saturation * b.value).compareTo(a.saturation * a.value));
      final top = px.take(math.max(1, px.length ~/ 5)).toList();
      if (top.isNotEmpty && top.first.saturation > 0.18) {
        // Average hue on the colour circle.
        var sx = 0.0, sy = 0.0, sat = 0.0;
        for (final c in top) {
          sx += math.cos(c.hue * math.pi / 180);
          sy += math.sin(c.hue * math.pi / 180);
          sat += c.saturation;
        }
        final hue = (math.atan2(sy, sx) * 180 / math.pi + 360) % 360;
        out = HSVColor.fromAHSV(1, hue, (sat / top.length).clamp(0.55, 0.85), 0.92).toColor();
      }
    }
  } catch (_) {}
  _tintCache[key] = out;
  return out;
}

/// The wave colour for [t]: the cover's colour in Minimal, red in Crimson.
class WaveTint extends StatelessWidget {
  final Track? track;
  final Widget Function(BuildContext context, Color color) builder;
  const WaveTint({super.key, required this.track, required this.builder});

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (!isMinimal || t == null) return builder(context, kWaveRed);
    return FutureBuilder<Color?>(
      key: ValueKey(t.id),
      future: coverTint(store.artFor(t)),
      builder: (context, s) => builder(context, s.data ?? kWaveRed),
    );
  }
}

/// A progress line with a soft moving wave above the played part, like the
/// media player in Android's notification shade. The wave rises while music
/// plays and settles flat on pause.
class WaveProgress extends StatefulWidget {
  final double value;
  final bool playing;
  final Color color;

  /// Colour of the unplayed part of the line (transparent hides it).
  final Color? trackColor;
  final double lineWidth;

  /// Where the line sits, from 0 (top) to 1 (bottom) of the widget.
  final double baseline;

  /// How tall the wave may get, in pixels.
  final double waveHeight;
  final bool showLine;

  const WaveProgress({
    super.key,
    required this.value,
    required this.playing,
    required this.color,
    this.trackColor,
    this.lineWidth = 2.5,
    this.baseline = 1,
    this.waveHeight = 12,
    this.showLine = true,
  });

  @override
  State<WaveProgress> createState() => _WaveProgressState();
}

class _WaveProgressState extends State<WaveProgress> with TickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final AnimationController _amp = AnimationController(vsync: this, duration: const Duration(milliseconds: 700), value: widget.playing ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _amp.addStatusListener((s) {
      if (s == AnimationStatus.dismissed) _phase.stop();
    });
    if (widget.playing) _phase.repeat();
  }

  @override
  void didUpdateWidget(WaveProgress old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) {
      if (widget.playing) {
        if (!_phase.isAnimating) _phase.repeat();
        _amp.animateTo(1, curve: Curves.easeOutCubic);
      } else {
        _amp.animateTo(0, curve: Curves.easeInCubic);
      }
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    _amp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Tests and "reduce motion": no moving wave.
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_phase, _amp]),
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _WavePainter(
              value: widget.value.clamp(0.0, 1.0),
              phase: _phase.value,
              amp: still ? 0 : Curves.easeOut.transform(_amp.value),
              color: widget.color,
              track: widget.trackColor,
              lineWidth: widget.lineWidth,
              baseline: widget.baseline,
              waveHeight: widget.waveHeight,
              showLine: widget.showLine,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double value, phase, amp, lineWidth, baseline, waveHeight;
  final Color color;
  final Color? track;
  final bool showLine;
  _WavePainter({
    required this.value,
    required this.phase,
    required this.amp,
    required this.color,
    required this.track,
    required this.lineWidth,
    required this.baseline,
    required this.waveHeight,
    required this.showLine,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final y0 = (size.height * baseline).clamp(lineWidth / 2, size.height - lineWidth / 2);
    final played = w * value;

    if (amp > 0.01 && played > 4) {
      final h = math.min(waveHeight, y0) * amp;
      // Three layers at different speeds and sizes; the top one is lighter.
      const layers = [
        (freq: 1.6, speed: 1.0, size: 1.0, alpha: 0.42, white: 0.05),
        (freq: 2.7, speed: -1.6, size: 0.8, alpha: 0.48, white: 0.35),
        (freq: 4.1, speed: 2.3, size: 0.55, alpha: 0.6, white: 0.7),
      ];
      for (final l in layers) {
        final path = Path()..moveTo(0, y0);
        const step = 3.0;
        for (var x = 0.0; x <= played; x += step) {
          final u = x / math.max(w, 1);
          // Rises from nothing at the start, fullest near the playhead,
          // then eases down into it.
          final fromStart = (x / math.min(60, played)).clamp(0.0, 1.0);
          final toHead = ((played - x) / 14).clamp(0.0, 1.0);
          final env = fromStart * (0.45 + 0.55 * toHead) * (0.7 + 0.3 * (x / played));
          final t = phase * 2 * math.pi * l.speed;
          final s = 0.5 + 0.5 * math.sin(u * 2 * math.pi * l.freq * 3 + t) * math.cos(u * 2 * math.pi * l.freq * 1.3 - t * 0.7);
          path.lineTo(x, y0 - math.min(y0, h * 1.5 * l.size * env * (0.35 + 0.65 * s)));
        }
        path
          ..lineTo(played, y0)
          ..close();
        final top = Color.lerp(color, Colors.white, l.white)!;
        canvas.drawPath(
          path,
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(0, y0 - h),
              Offset(0, y0),
              [top.withValues(alpha: l.alpha * 0.55), top.withValues(alpha: l.alpha)],
            ),
        );
      }
    }

    if (!showLine) return;
    final line = Paint()
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round;
    if (track != null && track!.a > 0 && played < w) {
      canvas.drawLine(Offset(played, y0), Offset(w, y0), line..color = track!);
    }
    if (played > 0) canvas.drawLine(Offset(0, y0), Offset(played, y0), line..color = color);
  }

  @override
  bool shouldRepaint(_WavePainter o) => o.value != value || o.phase != phase || o.amp != amp || o.color != color || o.track != track || o.baseline != baseline;
}
