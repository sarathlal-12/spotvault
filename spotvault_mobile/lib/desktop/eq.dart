import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import '../app_state.dart';

/// Windows equaliser: 5 bands on mpv's audio filter (FFmpeg's equalizer).
class Eq {
  Eq._();
  static final Eq instance = Eq._();

  static const bands = <(int, String)>[(60, '60'), (230, '230'), (910, '910'), (3600, '3.6k'), (14000, '14k')];
  static const maxDb = 12.0;

  static const builtIn = <String, List<double>>{
    'Flat': [0, 0, 0, 0, 0],
    'Bass boost': [6, 4, 0, 0, 0],
    'Vocal': [-2, 0, 4, 3, 0],
    'Treble': [0, 0, 0, 3, 6],
    'Loudness': [5, 2, -1, 2, 5],
  };

  final _players = <Player>[];

  /// Called once at start-up (Windows), before the first song plays.
  void attach() {
    if (!Platform.isWindows) return;
    // Speed changes use mpv's own "speed" (pitch stays natural), which leaves
    // the audio filter free for the EQ.
    JustAudioMediaKit.pitch = false;
    JustAudioMediaKit.onPlayer = (p) {
      _players.add(p);
      _apply(p);
    };
  }

  String get _filter {
    if (!store.eqOn || store.eqGains.every((g) => g == 0)) return '';
    final parts = [
      for (final (i, (hz, _)) in bands.indexed)
        if (store.eqGains[i] != 0) 'equalizer=f=$hz:t=o:w=${i == 0 || i == bands.length - 1 ? 2 : 1.5}:g=${store.eqGains[i].toStringAsFixed(1)}',
    ];
    // A little headroom when boosting, so loud songs don't clip.
    final boost = store.eqGains.reduce((a, b) => a > b ? a : b);
    if (boost > 0) parts.add('volume=${(-boost * 0.6).toStringAsFixed(1)}dB');
    return 'lavfi=[${parts.join(',')}]';
  }

  Future<void> _apply(Player p) async {
    try {
      final native = p.platform;
      if (native is NativePlayer) await native.setProperty('af', _filter);
    } catch (e) {
      debugPrint('EQ: $e');
    }
  }

  /// Applies the current settings to every player and saves them.
  Future<void> update() async {
    store.changed();
    for (final p in List.of(_players)) {
      await _apply(p);
    }
  }
}

/// The EQ window: on/off, 5 sliders, presets (built-in and your own).
Future<void> showEqDialog(BuildContext context) => showDialog(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, setState) {
        final p = pal;
        final eq = Eq.instance;
        String? presetName() {
          for (final e in {...Eq.builtIn, ...store.eqPresets}.entries) {
            if (List.generate(5, (i) => e.value[i] == store.eqGains[i]).every((x) => x)) return e.key;
          }
          return null;
        }

        void set(List<double> g) {
          store.eqGains = List.of(g);
          store.eqOn = true;
          eq.update();
          setState(() {});
        }

        final current = presetName();
        return AlertDialog(
          title: Row(children: [
            const Expanded(child: Text('Equaliser')),
            Switch(
              value: store.eqOn,
              onChanged: (v) {
                store.eqOn = v;
                eq.update();
                setState(() {});
              },
            ),
          ]),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final name in [...Eq.builtIn.keys, ...store.eqPresets.keys])
                  InputChip(
                    label: Text(name),
                    selected: current == name && store.eqOn,
                    showCheckmark: false,
                    onPressed: () => set(Eq.builtIn[name] ?? store.eqPresets[name]!),
                    onDeleted: Eq.builtIn.containsKey(name)
                        ? null
                        : () {
                            store.eqPresets.remove(name);
                            eq.update();
                            setState(() {});
                          },
                  ),
              ]),
              const SizedBox(height: 18),
              Opacity(
                opacity: store.eqOn ? 1 : 0.45,
                child: SizedBox(
                  height: 230,
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    for (final (i, (_, label)) in Eq.bands.indexed)
                      Column(children: [
                        Text('${store.eqGains[i] > 0 ? '+' : ''}${store.eqGains[i].round()} dB', style: TextStyle(fontSize: 12, color: p.muted)),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              value: store.eqGains[i],
                              min: -Eq.maxDb,
                              max: Eq.maxDb,
                              divisions: 24,
                              onChanged: (v) {
                                store.eqGains[i] = v;
                                store.eqOn = true;
                                setState(() {});
                              },
                              onChangeEnd: (_) => eq.update(),
                            ),
                          ),
                        ),
                        Text('$label Hz', style: TextStyle(fontSize: 12, color: p.text)),
                      ]),
                  ]),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('Save as preset'),
              onPressed: () async {
                final ctrl = TextEditingController();
                final name = await showDialog<String>(
                  context: c,
                  builder: (d) => AlertDialog(
                    title: const Text('Preset name'),
                    content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v.trim())),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(d, ctrl.text.trim()), child: const Text('Save')),
                    ],
                  ),
                );
                if (name == null || name.isEmpty || Eq.builtIn.containsKey(name)) return;
                store.eqPresets[name] = List.of(store.eqGains);
                await eq.update();
                setState(() {});
              },
            ),
            TextButton(onPressed: () => set(Eq.builtIn['Flat']!), child: const Text('Reset')),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
          ],
        );
      }),
    );
