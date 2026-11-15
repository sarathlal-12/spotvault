import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/library_store.dart';
import 'package:spotvault_mobile/nearby.dart';
import 'package:spotvault_mobile/net_jam.dart';
import 'package:spotvault_mobile/pc_link.dart';
import 'package:spotvault_mobile/player_service.dart';
import 'package:spotvault_mobile/sync_service.dart';

/// Internet Jam against a running relay. Skipped unless JAM_RELAY is set, e.g.
///   cd jam-relay && cf dev     (then)  JAM_RELAY=http://localhost:5173 flutter test test/net_jam_e2e_test.dart
NetJamService _phone(String name, {bool approve = true}) {
  final s = LibraryStore()..deviceName = name;
  s.baseDir = Directory.systemTemp.createTempSync('nj_$name');
  final player = PlayerService(s);
  final nearby = NearbyService(s, player, port: 0, name: name, id: name)..onJoinRequest = (_) async => approve;
  return NetJamService(s, player, PcLink(s, SyncService(s)), nearby);
}

Future<void> _until(bool Function() ok, {int ms = 8000}) async {
  for (var i = 0; i < ms ~/ 50 && !ok(); i++) {
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final relay = Platform.environment['JAM_RELAY'];
  // The audio player needs a binding; real network calls need the real HttpClient.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('a friend joins an internet Jam after the host lets them in', () async {
    jamRelay = relay!;
    final host = _phone('Host');
    final guest = _phone('Friend');

    expect(await host.host(), isNull);
    expect(host.code, hasLength(6));

    expect(await guest.join(host.code.toLowerCase()), isNull);
    await _until(() => host.guests.isNotEmpty);
    expect(host.guests.single.name, 'Friend');
    await _until(() => guest.status == null);
    expect(guest.role, NetRole.guest);
    expect(guest.hostName, 'Host');

    // The guest's clock lines up with the relay's.
    await _until(() => guest.serverNow != DateTime.now().millisecondsSinceEpoch, ms: 2000);

    await host.leave();
    await _until(() => !guest.active);
    expect(guest.active, isFalse);
    expect(guest.status, 'The Jam ended.');

    expect(await guest.join('ZZZZZZ'), contains('No Jam'));
  }, skip: relay == null ? 'Set JAM_RELAY to a running relay' : false);

  test('a declined friend is told no', () async {
    jamRelay = relay!;
    final host = _phone('Host2', approve: false);
    final guest = _phone('Other');
    expect(await host.host(), isNull);
    expect(await guest.join(host.code), isNull);
    await _until(() => !guest.active);
    expect(guest.status, 'Host2 said no.');
    await host.leave();
  }, skip: relay == null ? 'Set JAM_RELAY to a running relay' : false);
}
