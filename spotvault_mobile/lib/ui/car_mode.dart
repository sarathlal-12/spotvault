import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_state.dart';
import 'aurora.dart';
import 'common.dart';

void openCarMode(BuildContext context) {
  Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (_, __, ___) => const CarModeScreen(),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: child),
  ));
}

/// Studio card that opens Car mode.
class CarModeCard extends StatelessWidget {
  const CarModeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Pressable(
      onTap: () => openCarMode(context),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: p.dark ? p.raised : p.text, borderRadius: BorderRadius.circular(24)),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: const Color(0xFFE0403B), borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.directions_car_filled_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Car mode', style: TextStyle(color: p.dark ? p.text : p.bg, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text('Big buttons, swipe to skip, screen stays on.', style: TextStyle(color: (p.dark ? p.text : p.bg).withValues(alpha: 0.65), fontSize: 12)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: p.dark ? p.text : p.bg),
        ]),
      ),
    );
  }
}

/// Studio card: your name, the look (Minimal or Crimson) and light/dark.
class LookCard extends StatelessWidget {
  const LookCard({super.key});

  Future<void> _style(String s) async {
    store.themeStyle = s;
    themeStyle.value = s;
    await store.save();
  }

  Future<void> _player(String look) async {
    store.playerLook = look;
    store.changed();
    await store.save();
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: store.userName);
    final v = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 30, textCapitalization: TextCapitalization.words, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null) {
      store.userName = v.trim();
      store.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    Widget chip(String label, bool on, VoidCallback tap) => ChoiceChip(label: Text(label), selected: on, showCheckmark: false, onSelected: (_) => tap());
    return GlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Look', style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700))),
          TextButton.icon(
            onPressed: () => _rename(context),
            icon: const Icon(Icons.edit_rounded, size: 16),
            label: Text(store.userName.trim().isEmpty ? 'Add your name' : store.userName.trim()),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          chip('Minimal', isMinimal, () => _style('minimal')),
          chip('Crimson', !isMinimal, () => _style('crimson')),
          const SizedBox(width: 6),
          chip('Dark', darkMode.value, () => setDarkMode(true)),
          chip('Light', !darkMode.value, () => setDarkMode(false)),
        ]),
        const SizedBox(height: 12),
        Text('Player', style: TextStyle(color: p.muted, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        ListenableBuilder(
          listenable: store,
          builder: (context, _) => Wrap(spacing: 8, runSpacing: 8, children: [
            chip('Classic', store.playerLook != 'focus', () => _player('classic')),
            chip('Focus', store.playerLook == 'focus', () => _player('focus')),
          ]),
        ),
      ]),
    );
  }
}

/// A simple, high-contrast player for driving.
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key});

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((_) {});
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  Widget _big(IconData icon, String label, VoidCallback onTap, {bool light = false, double size = 52}) => Semantics(
        button: true,
        label: label,
        child: Material(
          color: light ? const Color(0xFFF2EFE8) : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: () {
              HapticFeedback.mediumImpact();
              onTap();
            },
            child: Center(child: Icon(icon, size: size, color: light ? const Color(0xFF0B0B0C) : const Color(0xFFF2EFE8))),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0C),
      body: SafeArea(
        child: GestureDetector(
          // Swipe left for next, right for previous.
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) playerService.next();
            if (v > 300) playerService.previous();
          },
          child: ListenableBuilder(
            listenable: playerService,
            builder: (context, _) {
              final t = playerService.current;
              return Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Text('CAR MODE', style: TextStyle(color: Color(0xFFE0403B), fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                    const Spacer(),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24), minimumSize: const Size(88, 48), shape: const StadiumBorder()),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Exit'),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Row(children: [
                    if (t != null) TrackArt(t, size: 96, radius: 22) else Container(width: 96, height: 96, decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(22))),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t?.title ?? 'Nothing playing', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700, height: 1.15)),
                        const SizedBox(height: 4),
                        Text(t?.subtitle ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFA09C96), fontSize: 16)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  StreamBuilder<Duration>(
                    stream: playerService.player.positionStream,
                    builder: (context, s) {
                      final total = playerService.player.duration?.inMilliseconds ?? 0;
                      final v = total == 0 ? 0.0 : ((s.data?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0);
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(value: v, minHeight: 6, color: const Color(0xFFE0403B), backgroundColor: Colors.white12),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: Column(children: [
                      Expanded(
                        child: Row(children: [
                          Expanded(child: _big(Icons.skip_previous_rounded, 'Previous', playerService.previous)),
                          const SizedBox(width: 12),
                          Expanded(child: _big(Icons.skip_next_rounded, 'Next', playerService.next)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        flex: 2,
                        child: StreamBuilder<PlayerState>(
                          stream: playerService.player.playerStateStream,
                          builder: (context, s) {
                            final playing = s.data?.playing ?? false;
                            return SizedBox(
                              width: double.infinity,
                              child: _big(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, playing ? 'Pause' : 'Play', playerService.togglePlay, light: true, size: 72),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Row(children: [
                          Expanded(
                            child: _big(playerService.shuffleOn ? Icons.shuffle_on_rounded : Icons.shuffle_rounded, 'Shuffle', playerService.toggleShuffle, size: 40),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: _big(Icons.favorite_rounded, 'Like', () { if (t != null) store.toggleLike(t.id); }, size: 40)),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}
