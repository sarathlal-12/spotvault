import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app_state.dart';
import '../player_service.dart';
import 'aurora.dart';

/// Sound settings: speed, smooth transitions, even volume, equalizer.
void showSoundSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.95,
      builder: (_, scroll) => ListenableBuilder(
        listenable: Listenable.merge([playerService, store]),
        builder: (context, _) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: [
            Text('Sound', style: displayStyle(22)),
            const SizedBox(height: 14),
            _label('Playback speed'),
            Wrap(spacing: 8, children: [
              for (final s in [0.75, 1.0, 1.25, 1.5])
                ChoiceChip(
                  label: Text('$s×'),
                  selected: playerService.player.speed == s,
                  onSelected: (_) => playerService.setSpeed(s),
                ),
            ]),
            const SizedBox(height: 18),
            _label('Smooth transitions'),
            Text(
              store.crossfadeSec == 0 ? 'Off: songs change straight away' : 'Fades out and into the next song over ${store.crossfadeSec} s',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            Slider(
              value: store.crossfadeSec.toDouble(),
              max: 12,
              divisions: 12,
              label: store.crossfadeSec == 0 ? 'Off' : '${store.crossfadeSec} s',
              onChanged: (v) => playerService.setSound(crossfadeSec: v.round()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: store.evenVolume,
              onChanged: (v) => playerService.setSound(evenVolume: v),
              title: const Text('Even volume'),
              subtitle: Text(
                  'Turns loud songs down so every song plays at a similar level. '
                  'Your PC measures songs it syncs.',
                  style: TextStyle(color: kMuted, fontSize: 12)),
            ),
            const SizedBox(height: 8),
            if (Platform.isAndroid && playerService.equalizer != null) _Equalizer(eq: playerService.equalizer!),
          ],
        ),
      ),
    ),
  );
}

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
    );

class _Equalizer extends StatefulWidget {
  final AndroidEqualizer eq;
  const _Equalizer({required this.eq});

  @override
  State<_Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<_Equalizer> {
  late final Future<AndroidEqualizerParameters> _params = widget.eq.parameters;

  static const _names = {
    'off': 'Off',
    'bass': 'Bass boost',
    'vocal': 'Vocals',
    'treble': 'Treble',
    'acoustic': 'Acoustic',
    'custom': 'Custom'
  };

  String _hz(double hz) => hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)}k' : '${hz.round()}';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Equalizer'),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final p in PlayerService.eqPresets)
            ChoiceChip(label: Text(_names[p]!), selected: store.eqPreset == p, onSelected: (_) => playerService.setSound(eqPreset: p)),
        ]),
        const SizedBox(height: 10),
        FutureBuilder<AndroidEqualizerParameters>(
          future: _params,
          builder: (context, snap) {
            final params = snap.data;
            if (params == null) return const SizedBox(height: 8);
            final custom = store.eqPreset == 'custom';
            return SizedBox(
              height: 190,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (var i = 0; i < params.bands.length; i++)
                    Expanded(
                      child: Column(children: [
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              min: params.minDecibels,
                              max: params.maxDecibels,
                              value: (store.eqPreset == 'off'
                                      ? 0.0
                                      : custom
                                          ? (i < store.eqCustom.length ? store.eqCustom[i] : 0.0)
                                          : PlayerService.presetGain(store.eqPreset, params.bands[i].centerFrequency))
                                  .clamp(params.minDecibels, params.maxDecibels),
                              onChanged: (v) {
                                final list = List<double>.generate(
                                    params.bands.length,
                                    (j) => custom
                                        ? (j < store.eqCustom.length ? store.eqCustom[j] : 0.0)
                                        : (store.eqPreset == 'off'
                                            ? 0.0
                                            : PlayerService.presetGain(store.eqPreset, params.bands[j].centerFrequency)));
                                list[i] = v;
                                store.eqCustom = list;
                                playerService.setSound(eqPreset: 'custom');
                              },
                            ),
                          ),
                        ),
                        Text(_hz(params.bands[i].centerFrequency), style: TextStyle(fontSize: 11, color: kMuted)),
                      ]),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
