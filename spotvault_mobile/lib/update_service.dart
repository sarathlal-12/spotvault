import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// This build's version. Must match `version:` in pubspec.yaml
/// (test/version_test.dart checks that).
const String kAppVersion = '1.5.0';

const String kRepo = 'sarathlal-12/spotvault';

/// A newer approved release. "Approved" = the GitHub release marked Latest;
/// pre-releases are invisible to the apps until approved in the admin panel.
class UpdateInfo {
  final String version;
  final String notes;
  final String pageUrl;
  final String? downloadUrl; // the APK on Android, the IPA on iPhone
  UpdateInfo(this.version, this.notes, this.pageUrl, this.downloadUrl);
}

List<int> parseVersion(String text) {
  final nums = RegExp(r'\d+').allMatches(text).take(3).map((m) => int.parse(m.group(0)!)).toList();
  while (nums.length < 3) {
    nums.add(0);
  }
  return nums;
}

bool isNewer(String latest, String current) {
  final a = parseVersion(latest), b = parseVersion(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

/// Returns the approved release if it is newer than this app, else null.
/// Throws when offline, so a manual check can say so.
Future<UpdateInfo?> checkForUpdate({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c.get(
      Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'SpotVault-Updater'},
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final version = ((j['tag_name'] as String?) ?? '').replaceFirst(RegExp(r'^[vV]'), '');
    if (version.isEmpty || !isNewer(version, kAppVersion)) return null;
    final ext = Platform.isIOS ? '.ipa' : '.apk';
    String? url;
    for (final a in (j['assets'] as List? ?? const [])) {
      final name = (a['name'] as String? ?? '').toLowerCase();
      if (name.endsWith(ext)) {
        url = a['browser_download_url'] as String?;
        break;
      }
    }
    return UpdateInfo(
      version,
      ((j['body'] as String?) ?? '').trim(),
      (j['html_url'] as String?) ?? 'https://github.com/$kRepo/releases/latest',
      url,
    );
  } finally {
    if (client == null) c.close();
  }
}
