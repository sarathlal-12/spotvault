import 'package:flutter/material.dart';

import '../app_state.dart';
import '../pc_link.dart';
import 'aurora.dart';
import 'search_screen.dart' show saveOnlineSongFlow;

/// Countries with Apple Music and YouTube Music charts.
const List<(String, String)> kChartCountries = [
  ('IN', 'India'), ('US', 'United States'), ('GB', 'United Kingdom'), ('CA', 'Canada'), ('AU', 'Australia'),
  ('AE', 'UAE'), ('SA', 'Saudi Arabia'), ('PK', 'Pakistan'), ('BD', 'Bangladesh'), ('LK', 'Sri Lanka'),
  ('NP', 'Nepal'), ('SG', 'Singapore'), ('MY', 'Malaysia'), ('ID', 'Indonesia'), ('PH', 'Philippines'),
  ('JP', 'Japan'), ('KR', 'South Korea'), ('DE', 'Germany'), ('FR', 'France'), ('ES', 'Spain'),
  ('IT', 'Italy'), ('NL', 'Netherlands'), ('BR', 'Brazil'), ('MX', 'Mexico'), ('ZA', 'South Africa'),
  ('NG', 'Nigeria'), ('KE', 'Kenya'), ('EG', 'Egypt'), ('TR', 'Turkey'), ('NZ', 'New Zealand'),
];

String countryName(String code) => kChartCountries.where((c) => c.$1 == code).firstOrNull?.$2 ?? code;

/// Where the charts come from and how a song is played or saved: the phone's
/// own downloader (or the PC bridge) on phones, the engine on Windows.
abstract class TrendingBackend {
  Future<Map<String, dynamic>> load(String country, String chart);
  Future<Uri> previewUri(Map<String, dynamic> song);
  Future<void> save(BuildContext context, Map<String, dynamic> song);
}

String songKey(Map<String, dynamic> s) {
  final url = '${s['url'] ?? ''}';
  return url.isNotEmpty ? url : 'q:${s['title']} ${s['artist'] ?? ''}';
}

/// Phones: through the phone's downloader (or the PC, when bridged).
class PhoneTrendingBackend implements TrendingBackend {
  @override
  Future<Map<String, dynamic>> load(String country, String chart) => pcLink.trending(country: country, chart: chart);

  /// Apple chart songs have no link: find the best match by name first.
  Future<OnlineSong> _resolve(Map<String, dynamic> s) async {
    final url = '${s['url'] ?? ''}';
    if (url.isNotEmpty) {
      return OnlineSong(title: '${s['title']}', artist: '${s['artist'] ?? ''}', duration: '', url: url, thumb: '${s['art'] ?? ''}');
    }
    final found = await pcLink.search('${s['title']} ${s['artist'] ?? ''}'.trim(), source: 'ytmusic');
    if (found.isEmpty) throw PcException('No copy of this song found online.');
    final f = found.first;
    return OnlineSong(title: '${s['title']}', artist: '${s['artist'] ?? ''}', duration: f.duration, url: f.url, thumb: '${s['art'] ?? ''}'.isEmpty ? f.thumb : '${s['art']}');
  }

  @override
  Future<Uri> previewUri(Map<String, dynamic> s) async => pcLink.previewUri(await _resolve(s));

  @override
  Future<void> save(BuildContext context, Map<String, dynamic> s) async {
    final song = await _resolve(s);
    if (context.mounted) await saveOnlineSongFlow(context, song);
  }
}

/// Today's top songs: pick a country and a chart, tap to listen, save to keep.
class TrendingView extends StatefulWidget {
  final TrendingBackend backend;

  /// Extra buttons in the header (song recognition).
  final List<Widget> actions;
  final EdgeInsets padding;
  const TrendingView({super.key, required this.backend, this.actions = const [], this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 180)});

  @override
  State<TrendingView> createState() => _TrendingViewState();
}

class _TrendingViewState extends State<TrendingView> {
  List<Map<String, dynamic>> charts = const [];
  List<Map<String, dynamic>>? songs;
  String chart = 'apple';
  String error = '';
  String? loadingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      songs = null;
      error = '';
    });
    try {
      final j = await widget.backend.load(store.trendCountry, chart);
      if (!mounted) return;
      setState(() {
        charts = [for (final c in (j['charts'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
        songs = [for (final s in (j['songs'] as List? ?? const [])) (s as Map).cast<String, dynamic>()];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e is PcException ? e.message : "Couldn't load the chart. Check your internet connection.");
    }
  }

  Future<void> _pickCountry() async {
    final code = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            for (final (code, name) in kChartCountries)
              ListTile(
                title: Text(name),
                trailing: code == store.trendCountry ? Icon(Icons.check_rounded, color: pal.accent) : null,
                onTap: () => Navigator.pop(c, code),
              ),
          ]),
        ),
      ),
    );
    if (code == null || code == store.trendCountry) return;
    store.trendCountry = code;
    store.changed();
    chart = 'apple'; // YouTube lists differ per country
    _load();
  }

  Future<void> _play(Map<String, dynamic> s) async {
    final key = songKey(s);
    if (playerService.previewing && playerService.previewKey == key) {
      await playerService.stopPreview();
      return;
    }
    setState(() => loadingKey = key);
    try {
      final uri = await widget.backend.previewUri(s);
      await playerService.playPreview(uri, key: key, title: '${s['title']}', artist: '${s['artist'] ?? ''}', artUrl: '${s['art'] ?? ''}');
    } catch (e) {
      if (mounted) _snack(e is PcException ? e.message : "Couldn't play this song. Try another one.");
    } finally {
      if (mounted) setState(() => loadingKey = null);
    }
  }

  Future<void> _save(Map<String, dynamic> s) async {
    try {
      await widget.backend.save(context, s);
    } catch (e) {
      if (mounted) _snack(e is PcException ? e.message : "Couldn't save this song. Try again.");
    }
  }

  void _snack(String t) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final list = songs;
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) => ListView(padding: widget.padding, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Today's top songs", style: TextStyle(fontSize: 13, color: p.muted)),
              const SizedBox(height: 2),
              splitTitle('Trending now', displayStyle(28)),
            ]),
          ),
          ...widget.actions,
        ]),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            ActionChip(
              avatar: const Icon(Icons.public_rounded, size: 18),
              label: Text(countryName(store.trendCountry)),
              onPressed: _pickCountry,
            ),
            const SizedBox(width: 8),
            for (final c in charts) ...[
              ChoiceChip(
                label: Text('${c['title']}'),
                selected: c['id'] == chart,
                showCheckmark: false,
                onSelected: (_) {
                  if (c['id'] == chart) return;
                  chart = '${c['id']}';
                  _load();
                },
              ),
              const SizedBox(width: 8),
            ],
          ]),
        ),
        const SizedBox(height: 10),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Column(children: [
              Text(error, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
              const SizedBox(height: 10),
              OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
            ]),
          )
        else if (list == null)
          Padding(padding: const EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: p.accent)))
        else if (list.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('This chart is empty right now.', textAlign: TextAlign.center, style: TextStyle(color: p.muted)))
        else
          for (final (i, s) in list.indexed) _row(i, s),
      ]),
    );
  }

  Widget _row(int i, Map<String, dynamic> s) {
    final p = pal;
    final key = songKey(s);
    final playing = playerService.previewing && playerService.previewKey == key;
    final art = '${s['art'] ?? ''}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 26, child: Text('${i + 1}', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontWeight: FontWeight.w600))),
        const SizedBox(width: 6),
        ClipOval(
          child: SizedBox(
            width: 46,
            height: 46,
            child: art.isEmpty
                ? Container(color: p.card, child: Icon(Icons.music_note_rounded, color: p.muted))
                : Image.network(art, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: p.card)),
          ),
        ),
      ]),
      title: Text('${s['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
      subtitle: Text('${s['artist'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 12)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: playing ? 'Stop' : 'Listen',
          onPressed: () => _play(s),
          icon: loadingKey == key
              ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent))
              : Icon(playing ? Icons.stop_circle_rounded : Icons.play_circle_outline_rounded, color: playing ? p.accent : p.text),
        ),
        IconButton(tooltip: 'Save to a playlist', onPressed: () => _save(s), icon: Icon(Icons.download_rounded, color: p.text)),
      ]),
      onTap: () => _play(s),
    );
  }
}
