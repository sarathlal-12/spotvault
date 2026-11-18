import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A soft wavy circle (the Cloud look's cover shape and the Focus player).
Path wavePath(Size s, double inset, {double amp = 0.022, int lobes = 9}) {
  final c = Offset(s.width / 2, s.height / 2);
  final r = s.shortestSide / 2 - inset;
  final path = Path();
  for (var i = 0; i <= 240; i++) {
    final a = i / 240 * math.pi * 2 - math.pi / 2;
    final rr = r * (1 - amp + amp * math.cos(lobes * (a + math.pi / 2)));
    final pt = c + Offset(math.cos(a), math.sin(a)) * rr;
    i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
  }
  return path..close();
}

class WaveClipper extends CustomClipper<Path> {
  final double amp;
  final int lobes;
  const WaveClipper({this.amp = 0.035, this.lobes = 9});
  @override
  Path getClip(Size size) => wavePath(size, 0, amp: amp, lobes: lobes);
  @override
  bool shouldReclip(WaveClipper old) => old.amp != amp || old.lobes != lobes;
}
