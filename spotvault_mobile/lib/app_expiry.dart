import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iPhone only: SpotVault is installed with AltStore, which signs it for 7
/// days. The end date comes from the app's own signing file, which AltStore
/// replaces on every refresh, so after a refresh the countdown starts over by
/// itself. Android and Windows installs never expire, so none of this runs
/// there.
class AppExpiry extends ChangeNotifier {
  static const _ch = MethodChannel('spotvault/expiry');

  /// Only iPhones have an expiry.
  static bool get supported => !kIsWeb && Platform.isIOS;

  DateTime? expires;

  Duration? get left => expires?.difference(DateTime.now());

  /// Reads the end date and plans the reminders: every 2 days until it
  /// expires, plus one a few hours before.
  Future<void> refresh() async {
    if (!supported) return;
    try {
      final ms = await _ch.invokeMethod<int>('expiry');
      expires = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      expires = null;
    }
    notifyListeners();
    final end = expires;
    if (end == null) return;
    final times = <DateTime>[];
    final bodies = <String>[];
    for (var t = DateTime.now().add(const Duration(days: 2)); t.isBefore(end.subtract(const Duration(hours: 6))); t = t.add(const Duration(days: 2))) {
      times.add(t);
      bodies.add('SpotVault stops opening in ${describeLeft(end.difference(t))}. Open AltStore and refresh it to keep using it.');
    }
    final last = end.subtract(const Duration(hours: 3));
    if (last.isAfter(DateTime.now())) {
      times.add(last);
      bodies.add('SpotVault stops opening in about 3 hours. Refresh it in AltStore now.');
    }
    try {
      await _ch.invokeMethod('schedule', {
        'times': [for (final t in times) t.millisecondsSinceEpoch],
        'title': 'Refresh SpotVault',
        'bodies': bodies,
      });
    } catch (_) {}
  }
}

/// "5 days 3 hours", "20 hours", "15 minutes".
String describeLeft(Duration d) {
  if (d.isNegative) return 'no time';
  if (d.inDays >= 1) {
    final h = d.inHours % 24;
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'}${h > 0 ? ' $h hour${h == 1 ? '' : 's'}' : ''}';
  }
  if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
  return '${d.inMinutes.clamp(1, 59)} minutes';
}

final AppExpiry appExpiry = AppExpiry();
