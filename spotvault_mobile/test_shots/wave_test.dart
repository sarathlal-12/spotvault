import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/ui/wave_progress.dart';

void main() {
  testWidgets('wave shot', (t) async {
    await t.binding.setSurfaceSize(const Size(420, 260));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: Column(children: [
          const SizedBox(height: 40),
          Container(
            margin: const EdgeInsets.all(12),
            height: 64,
            decoration: BoxDecoration(color: const Color(0xF2171717), borderRadius: BorderRadius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: const Stack(children: [
              Positioned(left: 0, right: 0, bottom: 0, height: 18, child: WaveProgress(value: 0.55, playing: true, color: kWaveRed, waveHeight: 14)),
            ]),
          ),
          const SizedBox(height: 30),
          const SizedBox(height: 48, child: Padding(padding: EdgeInsets.symmetric(horizontal: 26), child: WaveProgress(value: 0.4, playing: true, color: Color(0xFF4FA3E0), baseline: 0.5, waveHeight: 18, trackColor: Colors.white24))),
        ]),
      ),
    ));
    await t.pump(const Duration(milliseconds: 900));
    await expectLater(find.byType(Scaffold), matchesGoldenFile('out/wave.png'));
  });
}
