import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../phone_dedupe.dart';

/// Sync tab > More > Clean up duplicates: songs stored on the phone more than
/// once (downloaded on the phone or synced from the PC). Identical copies merge in one tap; for the same song downloaded twice
/// you pick the copy to keep (the best quality one is picked for you).
class DupesScreen extends StatefulWidget {
  const DupesScreen({super.key});

  @override
  State<DupesScreen> createState() => _DupesScreenState();
}

class _DupesScreenState extends State<DupesScreen> {
  List<DupeGroup>? groups;
  bool busy = false;
  int freedTotal = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final g = await findPhoneDupes();
    if (mounted) setState(() => groups = g);
  }

  Future<void> _merge(List<DupeGroup> which) async {
    setState(() => busy = true);
    var freed = 0;
    for (final g in which) {
      freed += await mergeDupes(g);
    }
    freedTotal += freed;
    final left = await findPhoneDupes();
    if (!mounted) return;
    setState(() {
      busy = false;
      groups = left;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Freed ${formatBytes(freed)}')));
  }

  String _where(Track t) {
    final names = [
      for (final p in store.playlists)
        if (p.trackIds.contains(t.id)) p.name,
    ];
    return names.isEmpty ? 'In no playlist' : names.join(', ');
  }

  String _quality(Track t) {
    final kbps = t.duration > 0 ? (t.size * 8 / t.duration / 1000).round() : 0;
    return [if (!t.phoneOnly) 'from PC', formatBytes(t.size), if (kbps > 0) '$kbps kbps', if (t.duration > 0) formatDuration(t.length)]
        .join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final g = groups;
    final exact = g?.where((x) => x.exact).toList() ?? const <DupeGroup>[];
    final near = g?.where((x) => !x.exact).toList() ?? const <DupeGroup>[];
    final exactBytes = exact.fold(0, (s, x) => s + x.freeBytes);
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicate songs')),
      body: g == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              Text(
                'Songs stored on this phone more than once, including ones that came from your PC. One copy stays and shows up in '
                'every playlist it was in. A later PC sync keeps it that way.',
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              if (g.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(children: [
                    Icon(Icons.check_circle_outline_rounded, size: 48, color: kAccent),
                    const SizedBox(height: 10),
                    Text(freedTotal > 0 ? 'All clean. You freed ${formatBytes(freedTotal)}.' : 'No duplicate songs on this phone.',
                        textAlign: TextAlign.center),
                  ]),
                ),
              if (exact.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${exact.length} songs saved twice (identical files)', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text('Merging them frees ${formatBytes(exactBytes)}. Nothing changes in your playlists.',
                          style: TextStyle(color: kMuted, fontSize: 13)),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: busy ? null : () => _merge(exact),
                        icon: const Icon(Icons.merge_rounded),
                        label: const Text('Merge identical copies'),
                      ),
                    ]),
                  ),
                ),
              if (near.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('Same song, downloaded twice', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 4),
                Text('Pick the copy to keep. The best quality one is picked for you. The others are deleted.',
                    style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 8),
                for (final x in near)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final t in x.copies)
                          RadioListTile<String>(
                            value: t.id,
                            // ignore: deprecated_member_use
                            groupValue: x.keep.id,
                            // ignore: deprecated_member_use
                            onChanged: busy ? null : (_) => setState(() => x.keep = t),
                            title: Text(t.artist.isEmpty ? t.title : '${t.title} · ${t.artist}', maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${_quality(t)}\n${_where(t)}', style: TextStyle(color: kMuted, fontSize: 12)),
                            isThreeLine: true,
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonal(
                            onPressed: busy ? null : () => _merge([x]),
                            child: Text('Keep this one · free ${formatBytes(x.freeBytes)}'),
                          ),
                        ),
                      ]),
                    ),
                  ),
              ],
            ]),
    );
  }
}
