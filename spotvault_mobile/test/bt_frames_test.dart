import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/bt_share.dart';

void main() {
  test('BLE frames rebuild long messages and files in order', () async {
    final tmp = await Directory.systemTemp.createTemp('bt');
    final messages = <Map<String, dynamic>>[];
    final files = <String, List<int>>{};
    final reader = BleFrameReader(
      tmp: tmp,
      onMessage: messages.add,
      onFile: (name, f) => files[name] = f.readAsBytesSync(),
    );

    // A message longer than one frame (an offer with many songs).
    final offer = {
      't': 'offer',
      'songs': [for (var i = 0; i < 40; i++) {'id': 'song$i', 'title': 'Title number $i'}],
    };
    for (final f in BleFrame.message(offer, 20)) {
      expect(f.length, lessThanOrEqualTo(20));
      reader.add(f);
    }

    // A file split into small chunks.
    final data = Uint8List.fromList(List.generate(5000, (_) => Random(1).nextInt(256)));
    reader.add(BleFrame.of(BleFrame.fileStart, 'song1|audio'.codeUnits));
    for (var i = 0; i < data.length; i += 19) {
      reader.add(BleFrame.of(BleFrame.fileData, data.sublist(i, min(i + 19, data.length))));
    }
    reader.add(BleFrame.of(BleFrame.fileEnd));
    for (final f in BleFrame.message({'t': 'end'}, 20)) {
      reader.add(f);
    }

    expect(messages.length, 2);
    expect(messages.first['t'], 'offer');
    expect((messages.first['songs'] as List).length, 40);
    expect(messages.last['t'], 'end');
    expect(files['song1|audio'], data);
    await tmp.delete(recursive: true);
  });
}
