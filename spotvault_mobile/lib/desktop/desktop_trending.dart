import 'package:flutter/material.dart';

import '../ui/trending_view.dart';
import 'engine_client.dart';

/// Windows: the charts come through the engine; Save downloads into one of
/// the PC playlists (or a new one).
class DesktopTrendingBackend implements TrendingBackend {
  @override
  Future<Map<String, dynamic>> load(String country, String chart) =>
      loadTrending(() => engine.trending(country: country, chart: chart), country, chart);

  @override
  Future<Uri> previewUri(Map<String, dynamic> s) async => engine.streamFor(s);

  @override
  Future<void> save(BuildContext context, Map<String, dynamic> s) async {
    final target = await pickPcPlaylist(context, title: 'Save "${s['title']}" into');
    if (target == null || !context.mounted) return;
    final err = await downloadSongsInto(target, [s]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Saving "${s['title']}" into "$target". See Sync & downloads.')));
  }
}

/// Downloads songs ({title, artist, url}) into a PC playlist folder. Songs with a
/// link (YouTube, SoundCloud) go as they are into an existing playlist;
/// everything else is found by name, which also makes a new playlist.
Future<String?> downloadSongsInto(String folder, List<Map<String, dynamic>> songs) {
  final urls = [for (final s in songs) '${s['url'] ?? ''}'];
  final existing = engine.playlists.any((x) => x['folder'] == folder);
  if (existing && urls.every((u) => u.isNotEmpty)) return engine.downloadSongs(folder, urls);
  return engine.importLists({
    folder: [for (final s in songs) '${s['title']} - ${s['artist'] ?? ''}'.trim()],
  });
}

/// Pick one of the PC playlists, or type a new name.
Future<String?> pickPcPlaylist(BuildContext context, {String title = 'Save into'}) {
  final ctrl = TextEditingController();
  final names = [for (final x in engine.playlists) '${x['folder']}'].where((n) => n.isNotEmpty).toList();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'New playlist name', prefixIcon: Icon(Icons.add_rounded)),
            onSubmitted: (v) => v.trim().isEmpty ? null : Navigator.pop(c, v.trim()),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView(shrinkWrap: true, children: [
              for (final n in names)
                ListTile(leading: const Icon(Icons.queue_music_rounded), title: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis), onTap: () => Navigator.pop(c, n)),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => ctrl.text.trim().isEmpty ? null : Navigator.pop(c, ctrl.text.trim()), child: const Text('Create and save')),
      ],
    ),
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
