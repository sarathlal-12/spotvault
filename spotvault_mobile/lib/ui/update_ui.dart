import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../update_service.dart';

bool _checking = false;

/// Checks GitHub for an approved newer version.
/// [manual]: the user tapped "Check for updates", so always report the result
/// (and ignore "Skip this version").
Future<void> runUpdateCheck(BuildContext context, {required bool manual}) async {
  if (_checking) return;
  _checking = true;
  UpdateInfo? info;
  Object? error;
  try {
    info = await checkForUpdate();
  } catch (e) {
    error = e;
  } finally {
    _checking = false;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (error != null) {
    if (manual) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't check for updates. Check your internet and try again.")));
    }
    return;
  }
  if (info == null) {
    if (manual) messenger.showSnackBar(const SnackBar(content: Text("You're on the latest version (v$kAppVersion).")));
    return;
  }
  if (!manual && store.skipUpdate == info.version) return;
  await _showUpdateDialog(context, info);
}

Future<void> _showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('SpotVault ${info.version} is available'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('You have v$kAppVersion. Your music and playlists stay on the phone.',
                style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 14),
            Text("WHAT'S NEW", style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
            const SizedBox(height: 6),
            Text(info.notes.isEmpty ? 'Improvements and fixes.' : info.notes, style: const TextStyle(height: 1.4)),
            if (Platform.isIOS) ...[
              const SizedBox(height: 14),
              Text(
                'Added the SpotVault source in AltStore? Just tap Update there. '
                'Otherwise, Update downloads the new app file: open the Files app, tap the file, '
                'tap Share and choose AltStore. Your music stays on the phone.',
                style: TextStyle(color: kMuted, fontSize: 12, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: Text('Skip', style: TextStyle(color: kMuted))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'later'), child: const Text('Later')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, 'update'),
          child: const Text('Update'),
        ),
      ],
    ),
  );
  if (choice == 'skip') {
    store.skipUpdate = info.version;
    store.changed(persist: true);
  } else if (choice == 'update') {
    final url = Uri.parse(info.downloadUrl ?? info.pageUrl);
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open ${info.pageUrl} to download the update.')));
    }
  }
}
