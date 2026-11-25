import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';

const Duration kSeekStep = Duration(seconds: 10);

/// The "back 10 s" / "forward 10 s" button next to Play.
class SeekTenButton extends StatelessWidget {
  final bool forward;
  final double size;
  final Color? color;
  const SeekTenButton({super.key, required this.forward, this.size = 26, this.color});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: forward ? 'Forward 10 seconds' : 'Back 10 seconds',
        visualDensity: VisualDensity.compact,
        iconSize: size,
        icon: Icon(forward ? Icons.forward_10_rounded : Icons.replay_10_rounded, color: color ?? pal.text),
        onPressed: () => playerService.seekBy(forward ? kSeekStep : -kSeekStep),
      );
}

/// Double-tap the left half of [child] to go back 10 s, the right half to go
/// forward (like YouTube). A short "-10 s" / "+10 s" bubble confirms it.
class DoubleTapSeek extends StatefulWidget {
  final Widget child;
  const DoubleTapSeek({super.key, required this.child});

  @override
  State<DoubleTapSeek> createState() => _DoubleTapSeekState();
}

class _DoubleTapSeekState extends State<DoubleTapSeek> {
  Offset _at = Offset.zero;
  bool? _forward;
  int _taps = 0;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _go(double width) {
    final forward = _at.dx > width / 2;
    playerService.seekBy(forward ? kSeekStep : -kSeekStep);
    setState(() {
      _taps = _forward == forward ? _taps + 1 : 1;
      _forward = forward;
    });
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _forward = null);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTapDown: (d) => _at = d.localPosition,
          onDoubleTap: () => _go(box.maxWidth),
          child: Stack(alignment: Alignment.center, children: [
            widget.child,
            if (_forward != null)
              Align(
                alignment: _forward! ? const Alignment(0.7, 0) : const Alignment(-0.7, 0),
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(99)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_forward! ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 4),
                      Text('${_forward! ? '+' : '-'}${10 * _taps} s', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      );
}
