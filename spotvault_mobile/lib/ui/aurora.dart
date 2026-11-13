import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';

/// Two soft glowing orbs that drift slowly behind the content.
class AuroraBackground extends StatefulWidget {
  final Widget child;
  final double intensity;
  const AuroraBackground({super.key, required this.child, this.intensity = 1});

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 16))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: kBg)),
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                final a = _c.value * 2 * math.pi;
                return CustomPaint(
                  painter: _OrbPainter(
                    a: Offset(-0.15 + 0.08 * math.sin(a), -0.08 + 0.05 * math.cos(a)),
                    b: Offset(1.05 - 0.07 * math.cos(a), 0.32 + 0.06 * math.sin(a)),
                    colorA: pal.orbA,
                    colorB: pal.orbB,
                    intensity: widget.intensity,
                  ),
                );
              },
            ),
          ),
        ),
        Positioned.fill(child: widget.child),
      ],
    );
  }
}

class _OrbPainter extends CustomPainter {
  final Offset a, b;
  final Color colorA, colorB;
  final double intensity;
  _OrbPainter({required this.a, required this.b, required this.colorA, required this.colorB, required this.intensity});

  void _orb(Canvas canvas, Offset center, double r, Color c) {
    final paint = Paint()
      ..shader = RadialGradient(colors: [c.withValues(alpha: c.a * intensity), c.withValues(alpha: 0)])
          .createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    _orb(canvas, Offset(a.dx * w, a.dy * size.height), w * 0.85, colorA);
    _orb(canvas, Offset(b.dx * w, b.dy * size.height), w * 0.75, colorB);
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.a != a || old.b != b || old.colorA != colorA || old.intensity != intensity;
}

/// Frosted panel with a hairline border.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Gradient? gradient;
  final VoidCallback? onTap;
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 22, this.gradient, this.onTap});

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? (pal.dark ? pal.glass : pal.surface) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: kLine),
        boxShadow: pal.dark ? null : [BoxShadow(color: kViolet.withValues(alpha: 0.07), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Pressable(onTap: onTap!, child: box);
  }
}

/// Shrinks a little while pressed, then springs back.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const Pressable({super.key, required this.child, required this.onTap, this.onLongPress});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

/// Square icon button on glass, 44 px, used in screen headers.
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;
  const GlassIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onPressed,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: pal.dark ? pal.glass : pal.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: Icon(icon, size: 21, color: color ?? kText, semanticLabel: tooltip),
        ),
      ),
    );
  }
}

/// Sun/moon button that switches dark and light.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = darkMode.value;
    return Tooltip(
      message: dark ? 'Switch to light theme' : 'Switch to dark theme',
      child: Pressable(
        onTap: () => setDarkMode(!dark),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: pal.dark ? pal.glass : pal.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            transitionBuilder: (child, anim) => RotationTransition(
              turns: Tween(begin: 0.6, end: 1.0).animate(anim),
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: Icon(
              dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              key: ValueKey(dark),
              size: 21,
              color: kAccent,
            ),
          ),
        ),
      ),
    );
  }
}

/// Saves the theme and repaints the app.
void setDarkMode(bool dark) {
  store.darkTheme = dark;
  store.changed();
  darkMode.value = dark;
}

/// Animated equalizer bars for whatever is playing.
class EqBars extends StatefulWidget {
  final Color color;
  final double height;
  final int bars;
  final bool playing;
  const EqBars({super.key, required this.color, this.height = 16, this.bars = 4, this.playing = true});

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(EqBars old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_c.isAnimating) _c.repeat();
    if (!widget.playing && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => SizedBox(
          height: widget.height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < widget.bars; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  width: 3,
                  height: widget.height *
                      (widget.playing ? 0.3 + 0.7 * (0.5 + 0.5 * math.sin(_c.value * 2 * math.pi + i * 1.7)).abs() : 0.3),
                  decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A band of light that sweeps across its child every few seconds.
class Sheen extends StatefulWidget {
  final Widget child;
  final double radius;
  const Sheen({super.key, required this.child, this.radius = 26});

  @override
  State<Sheen> createState() => _SheenState();
}

class _SheenState extends State<Sheen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4500))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) {
                  // Sweep during the first 40% of the cycle, then rest.
                  final t = (_c.value / 0.4).clamp(0.0, 1.0);
                  return FractionalTranslation(
                    translation: Offset(-1.2 + 2.6 * Curves.easeInOut.transform(t), 0),
                    child: FractionallySizedBox(
                      widthFactor: 0.4,
                      alignment: Alignment.centerLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(alpha: pal.dark ? 0.10 : 0.35),
                            Colors.white.withValues(alpha: 0),
                          ]),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades and slides its child in once, after [delay].
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero});

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: const Cubic(0.2, 0.8, 0.2, 1));
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

/// Small pink "NEW" tag for Vault Lab features.
class NewTag extends StatelessWidget {
  const NewTag({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(color: kPink, borderRadius: BorderRadius.circular(99)),
        child: const Text('NEW', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Color(0xFF1A0B14))),
      );
}

/// Pulsing dot (used for "linked to PC").
class PulseDot extends StatefulWidget {
  final Color color;
  const PulseDot({super.key, this.color = kCyan});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.55 * (1 - _c.value)),
              spreadRadius: 10 * _c.value,
            ),
          ],
        ),
      ),
    );
  }
}

/// Header title in the app's display style.
TextStyle displayStyle(double size) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.6,
      height: 1.1,
      color: kText,
    );

/// Picks a pair of colors for art-less playlists, stable per name.
List<Color> artColorsFor(String key) {
  const sets = [
    [Color(0xFF8B5CF6), Color(0xFFEC4899)],
    [Color(0xFF0EA5E9), Color(0xFF22D3EE)],
    [Color(0xFFF97316), Color(0xFFE11D48)],
    [Color(0xFF1E1B4B), Color(0xFF8B5CF6)],
    [Color(0xFF059669), Color(0xFF22D3EE)],
    [Color(0xFFDB2777), Color(0xFFF59E0B)],
  ];
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return sets[h % sets.length];
}

/// Violet-to-cyan pill button.
class GradientButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;
  final double height;
  const GradientButton({super.key, this.icon, required this.label, this.onTap, this.height = 50});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      child: Pressable(
        onTap: onTap ?? () {},
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: enabled ? 1 : 0.5,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              gradient: kBrandGradient,
              borderRadius: BorderRadius.circular(99),
              boxShadow: [BoxShadow(color: kViolet.withValues(alpha: 0.45), blurRadius: 22, offset: const Offset(0, 10))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 8)],
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
