import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parseHost handles IP, port and URL forms', () {
    expect(SyncService.parseHost('192.168.0.5'), ('192.168.0.5', kHttpPort));
    expect(SyncService.parseHost(' 192.168.0.5:8080 '), ('192.168.0.5', 8080));
    expect(SyncService.parseHost('http://10.0.0.2:50505/'), ('10.0.0.2', 50505));
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });
}
