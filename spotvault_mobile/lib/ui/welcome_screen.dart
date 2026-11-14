import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';

/// First start (and once after updating to 2.0): your name and a look.
class WelcomeScreen extends StatefulWidget {
  final VoidCallback onDone;
  const WelcomeScreen({super.key, required this.onDone});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final TextEditingController name = TextEditingController(text: store.userName);
  String style = 'minimal';

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _pick(String s) {
    setState(() => style = s);
    themeStyle.value = s; // preview it right away
  }

  Future<void> _finish({bool skip = false}) async {
    if (!skip) store.userName = name.text.trim();
    store.themeStyle = style;
    themeStyle.value = style;
    await store.save();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 48, 28, 28),
              children: [
                const SpotVaultMark(size: 72),
                const SizedBox(height: 28),
                Text('Welcome to SpotVault.', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1.1, color: p.text, letterSpacing: -0.8)),
                const SizedBox(height: 6),
                Text('What should we call you?', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1.1, color: p.muted, letterSpacing: -0.8)),
                const SizedBox(height: 22),
                TextField(
                  controller: name,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 30,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Your name', counterText: ''),
                ),
                const SizedBox(height: 10),
                Text('${greeting()}${name.text.trim().isEmpty ? '' : ', ${name.text.trim()}'}',
                    style: TextStyle(color: p.muted, fontSize: 14)),
                const SizedBox(height: 26),
                Text('Pick a look', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
                const SizedBox(height: 4),
                Text('You can change it any time in Settings.', style: TextStyle(color: p.muted, fontSize: 13)),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _LookCard(title: 'Minimal', sub: 'Calm grey and black', style: 'minimal', selected: style == 'minimal', onTap: () => _pick('minimal'))),
                  const SizedBox(width: 12),
                  Expanded(child: _LookCard(title: 'Crimson', sub: 'The classic SpotVault look', style: 'crimson', selected: style == 'crimson', onTap: () => _pick('crimson'))),
                ]),
                const SizedBox(height: 32),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: p.text,
                    foregroundColor: p.bg,
                    minimumSize: const Size.fromHeight(56),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _finish,
                  child: const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 6),
                TextButton(onPressed: () => _finish(skip: true), child: Text('Skip for now', style: TextStyle(color: p.muted))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LookCard extends StatelessWidget {
  final String title, sub, style;
  final bool selected;
  final VoidCallback onTap;
  const _LookCard({required this.title, required this.sub, required this.style, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final look = paletteFor(darkMode.value, style);
    return Semantics(
      button: true,
      selected: selected,
      label: '$title look',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: selected ? p.accent : p.line, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // A tiny preview of the look.
            Container(
              height: 96,
              decoration: BoxDecoration(
                color: look.bg,
                borderRadius: BorderRadius.circular(14),
                gradient: style == 'crimson'
                    ? RadialGradient(center: const Alignment(-0.7, -0.8), radius: 1.3, colors: [look.orbA, look.bg])
                    : null,
              ),
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 46, height: 6, decoration: BoxDecoration(color: look.text, borderRadius: BorderRadius.circular(3))),
                const SizedBox(height: 6),
                Container(width: 30, height: 5, decoration: BoxDecoration(color: look.muted, borderRadius: BorderRadius.circular(3))),
                const Spacer(),
                Row(children: [
                  Container(width: 26, height: 26, decoration: BoxDecoration(color: look.card, borderRadius: BorderRadius.circular(7))),
                  const SizedBox(width: 6),
                  Container(width: 26, height: 26, decoration: BoxDecoration(color: look.card, borderRadius: BorderRadius.circular(7))),
                  const Spacer(),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(color: style == 'crimson' ? kViolet : look.text, shape: BoxShape.circle),
                    child: Icon(Icons.play_arrow_rounded, size: 16, color: style == 'crimson' ? Colors.white : look.bg),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: p.text))),
              if (selected) Icon(Icons.check_circle_rounded, size: 18, color: p.accent),
            ]),
            Text(sub, style: TextStyle(color: p.muted, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// The SpotVault logo: a bold S with a crimson play button in its spine.
class SpotVaultMark extends StatelessWidget {
  final double size;
  const SpotVaultMark({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(width: size, height: size, child: CustomPaint(painter: _MarkPainter(p.text, p.bg))),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final Color fg, bg;
  _MarkPainter(this.fg, this.bg);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100;
    canvas.scale(s);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 100), const Radius.circular(26)), Paint()..color = fg);
    final path = Path()
      ..moveTo(65, 35)
      ..cubicTo(64, 28, 58, 25, 50, 25)
      ..cubicTo(40, 25, 34, 30, 34, 37.5)
      ..cubicTo(34, 45.5, 42, 47.5, 50, 50)
      ..cubicTo(58, 52.5, 66, 54.5, 66, 62.5)
      ..cubicTo(66, 70, 60, 75, 50, 75)
      ..cubicTo(42, 75, 36, 72, 35, 65);
    canvas.drawPath(
        path,
        Paint()
          ..color = bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round);
    // The play button sits in the S's spine with a thin gap around it.
    Path tri(double r) {
      const cx = 48.5, cy = 50.0;
      final pts = [for (final a in [0.0, 2 * math.pi / 3, -2 * math.pi / 3]) Offset(cx + r * math.cos(a), cy + r * math.sin(a))];
      return Path()..addPolygon(pts, true);
    }

    canvas.drawPath(tri(13), Paint()..color = fg);
    canvas.drawPath(tri(8.2), Paint()..color = const Color(0xFFE0403B));
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.fg != fg || old.bg != bg;
}
