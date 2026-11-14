import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/player_service.dart';

void main() {
  test('queued songs go right after the current song in shuffle order', () {
    final o = QueueShuffleOrder();
    o.indices.addAll([3, 0, 4, 1, 2]); // playing 3, then 0, 4, 1, 2
    o.insertAfter = 3; // "Play next" while song 3 plays
    o.insert(4, 1); // new song becomes index 4; old 4 moves to 5
    expect(o.indices, [3, 4, 0, 5, 1, 2]);
    o.insertAfter = 4; // "Add to queue": after the song queued before
    o.insert(5, 1);
    expect(o.indices, [3, 4, 5, 0, 6, 1, 2]);
  });
}
