import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/ui/qr.dart';

void main() {
  test('Jam and PC links round-trip', () {
    final j = SpotLink.parse(jamLink('192.168.1.23', 50510, 'Saad'))!;
    expect([j.kind, j.host, j.port, j.name], ['jam', '192.168.1.23', 50510, 'Saad']);
    final p = SpotLink.parse(pcLinkFor('10.0.0.5', 50505, '123456'))!;
    expect([p.kind, p.host, p.port, p.pin], ['pc', '10.0.0.5', 50505, '123456']);
    expect(SpotLink.parse('spotvault://j?h=192.168.0.2&p=50510')!.kind, 'jam');
    expect(SpotLink.parse('https://evil.example/j?h=1.2.3.4&p=1'), isNull);
    expect(SpotLink.parse('spotvault://j?h=not-an-ip&p=1'), isNull);
  });
}
