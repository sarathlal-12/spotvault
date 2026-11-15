import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../net_jam.dart';
import '../pc_link.dart';
import 'aurora.dart' show displayStyle;
import 'common.dart';
import 'menus.dart' show toast;
import 'qr.dart';

/// The "Over the internet" part of the Jam screen.
class NetJamCard extends StatelessWidget {
  const NetJamCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.public_rounded, color: kAccent),
          const SizedBox(width: 10),
          Expanded(child: Text('Jam over the internet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: kText))),
        ]),
        const SizedBox(height: 6),
        Text('Friends anywhere hear the same song at the same moment. They join with a code or link, and you let them in.',
            style: TextStyle(color: kMuted, fontSize: 13, height: 1.3)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44), shape: const StadiumBorder()),
              onPressed: () => startNetJam(context),
              child: const Text('Start'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44), shape: const StadiumBorder()),
              onPressed: () => askNetJamCode(context),
              child: const Text('Join with code'),
            ),
          ),
        ]),
      ]),
    );
  }
}

Future<void> startNetJam(BuildContext context) async {
  final err = await netJam.host();
  if (!context.mounted) return;
  if (err != null) return toast(context, err);
  openNetJam(context);
}

Future<void> askNetJamCode(BuildContext context) async {
  final ctrl = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Join a Jam'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]'))],
        decoration: const InputDecoration(hintText: 'Code, like K7Q2MX'),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Join')),
      ],
    ),
  );
  if (code == null || code.trim().isEmpty || !context.mounted) return;
  await joinNetJam(context, code);
}

Future<void> joinNetJam(BuildContext context, String code) async {
  final err = await netJam.join(code);
  if (!context.mounted) return;
  if (err != null) return toast(context, err);
  openNetJam(context);
}

void openNetJam(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NetJamScreen()));

class NetJamScreen extends StatefulWidget {
  const NetJamScreen({super.key});

  @override
  State<NetJamScreen> createState() => _NetJamScreenState();
}

class _NetJamScreenState extends State<NetJamScreen> {
  @override
  void initState() {
    super.initState();
    netJam.addListener(_onChange);
  }

  @override
  void dispose() {
    netJam.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!netJam.active && mounted) {
      final msg = netJam.status;
      Navigator.of(context).maybePop();
      if (msg != null) toast(context, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([netJam, playerService]),
      builder: (context, _) {
        final host = netJam.role == NetRole.host;
        return Scaffold(
          appBar: AppBar(
            title: Text(host ? 'Your internet Jam' : "${netJam.hostName.isEmpty ? 'Internet' : "${netJam.hostName}'s"} Jam"),
            backgroundColor: Colors.transparent,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
            children: [
              if (netJam.status != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(netJam.status!, style: TextStyle(color: kMuted))),
                  ]),
                ),
              if (host) ..._host(context) else ..._guest(context),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: const StadiumBorder()),
                onPressed: () async {
                  await netJam.leave();
                  if (context.mounted) Navigator.of(context).maybePop();
                },
                icon: const Icon(Icons.logout_rounded),
                label: Text(host ? 'End Jam' : 'Leave Jam'),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _host(BuildContext context) {
    final link = netJamLink(netJam.code, netJam.hostName);
    final t = playerService.current;
    return [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: kText, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          Text('Jam code', style: TextStyle(color: kBg.withValues(alpha: 0.7), fontSize: 13)),
          const SizedBox(height: 4),
          SelectableText(netJam.code, style: TextStyle(color: kBg, fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 6)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: kBg),
              onPressed: () => showQrSheet(context, title: 'Join my Jam', subtitle: 'Scan with the phone camera or SpotVault, from anywhere.', link: link),
              icon: const Icon(Icons.qr_code_rounded),
              label: const Text('Show QR'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: kBg),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                toast(context, 'Link copied. Send it to your friends.');
              },
              icon: const Icon(Icons.link_rounded),
              label: const Text('Copy link'),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      Text('Play music as usual. Friends hear the same song, wherever they are.', style: TextStyle(color: kMuted, fontSize: 13)),
      if (t != null) ...[
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: TrackArt(t, size: 46, radius: 10),
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted)),
        ),
      ],
      const SizedBox(height: 18),
      Text('Listening (${netJam.guests.length})', style: displayStyle(18)),
      if (netJam.guests.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Nobody yet. Share the code or link.', style: TextStyle(color: kMuted))),
      for (final g in netJam.guests)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(backgroundColor: kAccent.withValues(alpha: 0.15), child: Icon(Icons.person_rounded, color: kAccent)),
          title: Text(g.name),
          trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.close_rounded), onPressed: () => netJam.kick(g.id)),
        ),
    ];
  }

  List<Widget> _guest(BuildContext context) {
    final song = netJam.nowPlaying;
    final playing = playerService.player.playing;
    return [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: pal.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: kLine)),
        child: Column(children: [
          Text('Now playing', style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 6),
          Text(song?.title ?? 'Nothing yet', textAlign: TextAlign.center, style: displayStyle(22), maxLines: 2, overflow: TextOverflow.ellipsis),
          if (song != null && song.artist.isNotEmpty) Text(song.artist, style: TextStyle(color: kMuted)),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Previous', iconSize: 30, onPressed: () => netJam.request('prev'), icon: const Icon(Icons.skip_previous_rounded)),
            const SizedBox(width: 12),
            IconButton.filled(
              tooltip: playing ? 'Pause for everyone' : 'Play for everyone',
              iconSize: 34,
              onPressed: () => netJam.request(playing ? 'pause' : 'play'),
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 12),
            IconButton(tooltip: 'Next', iconSize: 30, onPressed: () => netJam.request('next'), icon: const Icon(Icons.skip_next_rounded)),
          ]),
        ]),
      ),
      const SizedBox(height: 14),
      FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46), shape: const StadiumBorder()),
        onPressed: () => _addSong(context),
        icon: const Icon(Icons.playlist_add_rounded),
        label: const Text('Add a song'),
      ),
      const SizedBox(height: 18),
      Text('Up next', style: displayStyle(18)),
      if (netJam.upNext.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Nothing queued.', style: TextStyle(color: kMuted))),
      for (final s in netJam.upNext)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.music_note_rounded, color: kMuted),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: s.artist.isEmpty ? null : Text(s.artist, style: TextStyle(color: kMuted)),
        ),
    ];
  }

  Future<void> _addSong(BuildContext context) async {
    final song = await showModalBottomSheet<OnlineSong>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _SongPicker(),
    );
    if (song == null || !context.mounted) return;
    netJam.request('add', song: NetSong(song.title, song.artist, url: song.url, thumb: song.thumb));
    toast(context, 'Sent "${song.title}" to ${netJam.hostName.isEmpty ? 'the host' : netJam.hostName}');
  }
}

/// Search the web for a song to add to the Jam.
class _SongPicker extends StatefulWidget {
  const _SongPicker();

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  final ctrl = TextEditingController();
  List<OnlineSong> results = [];
  bool busy = false;
  String? error;

  Future<void> _search() async {
    final q = ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await pcLink.search(q);
      if (mounted) setState(() => results = r);
    } catch (_) {
      if (mounted) setState(() => error = "Search didn't work. Check your internet and try again.");
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Find a song',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: busy ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null,
            ),
          ),
          if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: TextStyle(color: kMuted))),
          Expanded(
            child: ListView(children: [
              for (final s in results)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text([s.artist, s.duration].where((x) => x.isNotEmpty).join(' · '), style: TextStyle(color: kMuted)),
                  trailing: Icon(Icons.add_circle_outline_rounded, color: kAccent),
                  onTap: () => Navigator.pop(context, s),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
