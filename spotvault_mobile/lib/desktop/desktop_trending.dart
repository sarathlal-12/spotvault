import 'package:flutter/material.dart';

import '../ui/trending_view.dart';
import 'engine_client.dart';

/// Windows: the charts come through the engine; Save downloads into one of
/// the PC playlists (or a new one).
class DesktopTrendingBackend implements TrendingBackend {
  @override
  Future<Map<String, dynamic>> load(String country, String chart) =>
      loadTrending(() => engine.trending(country: country, chart: chart), country, chart,
          fromDownloaderFor: (c) => engine.trending(country: country, chart: c));

  @override
  Future<Uri> previewUri(Map<String, dynamic> s) async => engine.streamFor(s);

  @override
  Future<Uri> streamFor(Map<String, dynamic> s) async => engine.streamFor(s);

  @override
  Future<void> save(BuildContext context, Map<String, dynamic> s) async {
    final targets = await pickPcPlaylists(context, title: 'Save "${s['title']}" into');
    if (targets == null || targets.isEmpty || !context.mounted) return;
    final err = await downloadSongsInto(targets, [s]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Saving "${s['title']}" into ${_names(targets)}. See Sync & downloads.')));
  }
}

String _names(List<String> f) => f.length == 1 ? '"${f.first}"' : '${f.length} playlists';

/// Downloads songs ({title, artist, url}) into PC playlist folders. The song is
/// downloaded once into the first folder and linked into the others, so it is
/// stored once. Songs with a link (YouTube, SoundCloud) go as they are into an
/// existing playlist; everything else is found by name, which also makes a new
/// playlist.
Future<String?> downloadSongsInto(List<String> folders, List<Map<String, dynamic>> songs) {
  final first = folders.first, also = folders.skip(1).toList();
  final urls = [for (final s in songs) '${s['url'] ?? ''}'];
  final existing = engine.playlists.any((x) => x['folder'] == first);
  if (existing && urls.every((u) => u.isNotEmpty)) return engine.downloadSongs(first, urls, also: also);
  return engine.importLists({
    first: [for (final s in songs) '${s['title']} - ${s['artist'] ?? ''}'.trim()],
  }, also: also);
}

/// Pick one or more PC playlists (tick boxes), or type a new name.
Future<List<String>?> pickPcPlaylists(BuildContext context, {String title = 'Save into', String? preselect, String action = 'Save'}) {
  final ctrl = TextEditingController();
  final names = <String>{if (preselect != null && preselect.isNotEmpty) preselect, for (final x in engine.playlists) '${x['folder']}'}.where((n) => n.isNotEmpty).toList();
  final ticked = <String>{if (preselect != null && names.contains(preselect)) preselect};
  return showDialog<List<String>>(
    context: context,
    builder: (c) => StatefulBuilder(builder: (c, setState) {
      final typed = ctrl.text.trim();
      final all = [...ticked, if (typed.isNotEmpty && !ticked.contains(typed)) typed];
      return AlertDialog(
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(shrinkWrap: true, children: [
                for (final n in names)
                  CheckboxListTile(
                    value: ticked.contains(n),
                    onChanged: (v) => setState(() => v == true ? ticked.add(n) : ticked.remove(n)),
                    secondary: const Icon(Icons.queue_music_rounded),
                    title: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'New playlist', hintText: 'Name', prefixIcon: Icon(Icons.add_rounded)),
              onSubmitted: (_) => all.isEmpty ? null : Navigator.pop(c, all),
            ),
            if (all.length > 1) ...[
              const SizedBox(height: 10),
              Text('Downloaded once and shown in every playlist you tick, so it takes no extra space.', style: TextStyle(fontSize: 12, color: Theme.of(c).hintColor)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: all.isEmpty ? null : () => Navigator.pop(c, all),
            child: Text(all.length > 1 ? '$action to ${all.length} playlists' : action),
          ),
        ],
      );
    }),
  );
}

class TrendingPage extends StatelessWidget {
  final List<Widget> actions;
  const TrendingPage({super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.transparent,
        child: TrendingView(backend: DesktopTrendingBackend(), actions: actions, padding: const EdgeInsets.fromLTRB(30, 28, 30, 120)),
      );
}
