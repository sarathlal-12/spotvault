import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/update_service.dart';

void main() {
  test('kAppVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final pubspec = line.split(':')[1].trim().split('+').first;
    expect(kAppVersion, pubspec, reason: 'Update kAppVersion in lib/update_service.dart');
  });

  test('version comparison', () {
    expect(isNewer('1.4.0', '1.3.0'), isTrue);
    expect(isNewer('v1.3.0', '1.3.0'), isFalse);
    expect(isNewer('1.3', '1.3.0'), isFalse);
    expect(isNewer('1.10.0', '1.9.0'), isTrue);
    expect(isNewer('1.2.9', '1.3.0'), isFalse);
  });
}
