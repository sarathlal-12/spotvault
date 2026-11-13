import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import 'aurora.dart';
import 'common.dart';

/// Vault Lab: features other players don't have.
class LabScreen extends StatelessWidget {
  const LabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 180),
          children: [
            FadeSlideIn(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Only in SpotVault', style: TextStyle(fontSize: 13, color: kMuted)),
                        const SizedBox(height: 2),
                        Text('Vault Lab', style: displayStyle(28)),
                      ],
                    ),
                  ),
                  const ThemeToggle(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const FadeSlideIn(delay: Duration(milliseconds: 60), child: _RewindCard()),
            const SizedBox(height: 14),
            const FadeSlideIn(delay: Duration(milliseconds: 120), child: _MomentsCard()),
            const SizedBox(height: 14),
            FadeSlideIn(
              delay: const Duration(milliseconds: 180),
              child: GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _FeatureRow(
                      glyph: Icons.bedtime_rounded,
                      tint: const Color(0xFFFACC15),
                      name: 'Smart Sleep',
                      desc: 'The sleep timer fades the music out slowly instead of stopping it suddenly.',
                      value: store.smartSleep,
                      onChanged: (v) {
                        store.smartSleep = v;
                        store.changed();
                      },
                    ),
                    _FeatureRow(
                      glyph: Icons.blur_on_rounded,
                      tint: const Color(0xFF94A3B8),
                      name: 'Ghost Queue',
                      desc: 'Songs you save from Search play next as soon as your PC sends them.',
                      value: store.ghostQueue,
                      onChanged: (v) {
                        store.ghostQueue = v;
                        store.changed();
                      },
                      divider: true,
                    ),
                    const _FeatureRow(
                      glyph: Icons.all_inclusive_rounded,
                      tint: kCyan,
                      name: 'A–B Loop',
                      desc: 'On Now Playing, tap A–B at the start and again at the end of the part to repeat.',
                      divider: true,
                    ),
                    const _FeatureRow(
                      glyph: Icons.add_location_alt_rounded,
                      tint: kPink,
                      name: 'Moments',
                      desc: 'On Now Playing, tap Moment to pin your favourite part. Tap a pin to jump back.',
                      divider: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RewindCard extends StatelessWidget {
  const _RewindCard();

  static String _hm(int ms) {
    final m = ms ~/ 60000;
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final month = store.listeningSince(DateTime(now.year, now.month, 1));
    final week = store.listeningByDay(7);
    final top = store.topArtist;
    final maxDay = week.fold<int>(1, math.max);
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return GlassCard(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('REWIND', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: kAccent)),
                  const SizedBox(width: 6),
                  const NewTag(),
                ]),
                const SizedBox(height: 8),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: month.toDouble()),
                  duration: const Duration(milliseconds: 1200),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, __) => Text(_hm(v.round()), style: displayStyle(32)),
                ),
                Text('this month, counted on this phone', style: TextStyle(fontSize: 12, color: kMuted)),
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: 'Top artist: ', style: TextStyle(color: kMuted)),
                    TextSpan(text: top ?? 'play something first', style: TextStyle(color: kText, fontWeight: FontWeight.w700)),
                  ]),
                  style: const TextStyle(fontSize: 13),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            label: 'Listening time over the last 7 days',
            child: SizedBox(
              width: 132,
              height: 100,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: 0.08 + 0.92 * week[i] / maxDay),
                              duration: Duration(milliseconds: 700 + 80 * i),
                              curve: Curves.easeOutBack,
                              builder: (_, f, __) => Container(
                                height: 78 * f.clamp(0.0, 1.1),
                                decoration: BoxDecoration(
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(6), bottom: Radius.circular(3)),
                                  gradient: i == 6 ? const LinearGradient(colors: [kCyan, kViolet], begin: Alignment.topCenter, end: Alignment.bottomCenter) : null,
                                  color: i == 6 ? null : kViolet.withValues(alpha: pal.dark ? 0.30 : 0.22),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(labels[now.subtract(Duration(days: 6 - i)).weekday - 1],
                                style: TextStyle(fontSize: 10, color: i == 6 ? kText : kMuted, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MomentsCard extends StatelessWidget {
  const _MomentsCard();

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final e in store.moments.entries)
        if (store.tracks[e.key] != null && e.value.isNotEmpty) (store.tracks[e.key]!, e.value)
    ];
    return GlassCard(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Text('YOUR MOMENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: kPink)),
            SizedBox(width: 6),
            NewTag(),
          ]),
          const SizedBox(height: 6),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('No Moments yet. While a song plays, tap Moment on Now Playing to pin your favourite part.',
                  style: TextStyle(color: kMuted, fontSize: 13, height: 1.4)),
            )
          else
            for (final (t, ms) in entries.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    TrackArt(t, size: 42, radius: 12),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: kText)),
                          Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: kMuted)),
                        ],
                      ),
                    ),
                    for (final m in ms.take(3))
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Pressable(
                          onTap: () => _playFrom(t, m),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 36),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: kPink.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(99),
                              border: Border.all(color: kPink.withValues(alpha: 0.4)),
                            ),
                            child: Text(formatDuration(Duration(milliseconds: m)),
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kText)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _playFrom(Track t, int ms) async {
    await playerService.playTracks([t]);
    await playerService.player.seek(Duration(milliseconds: ms));
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData glyph;
  final Color tint;
  final String name;
  final String desc;
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final bool divider;
  const _FeatureRow({
    required this.glyph,
    required this.tint,
    required this.name,
    required this.desc,
    this.value,
    this.onChanged,
    this.divider = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: divider ? Border(top: BorderSide(color: kLine)) : null),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: tint.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
            child: Icon(glyph, size: 20, color: pal.dark ? tint : Color.lerp(tint, Colors.black, 0.35)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kText)),
                  ),
                  const SizedBox(width: 6),
                  const NewTag(),
                ]),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 12, color: kMuted, height: 1.35)),
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 8),
            Switch(value: value!, onChanged: onChanged),
          ],
        ],
      ),
    );
  }
}
