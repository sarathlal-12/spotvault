import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../nearby.dart';
import 'aurora.dart';
import 'common.dart';
import 'menus.dart';

// ============================================================ share
/// "Share to a nearby phone": pick a phone, they tap Accept.
Future<void> shareFlow(BuildContext context, List<Track> tracks, PlaylistInfo? playlist) async {
  if (tracks.isEmpty) {
    toast(context, 'Nothing to share yet');
    return;
  }
  nearbyService.discover();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _ShareSheet(tracks: tracks, playlist: playlist, outer: context),
  );
}

class _ShareSheet extends StatefulWidget {
  final List<Track> tracks;
  final PlaylistInfo? playlist;
  final BuildContext outer;
  const _ShareSheet({required this.tracks, required this.playlist, required this.outer});

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  String? sendingTo;

  Future<void> _send(NearbyPhone p) async {
    setState(() => sendingTo = p.id);
    String msg;
    try {
      final ok = await nearbyService.share(p, widget.tracks, playlistName: widget.playlist?.name);
      msg = ok ? '${p.name} is getting ${_what()}' : '${p.name} said no';
    } catch (_) {
      msg = "Couldn't reach ${p.name}";
    }
    if (!mounted) return;
    Navigator.pop(context);
    if (widget.outer.mounted) toast(widget.outer, msg);
  }

  String _what() => widget.playlist != null
      ? '"${widget.playlist!.name}"'
      : widget.tracks.length == 1
          ? '"${widget.tracks.first.title}"'
          : '${widget.tracks.length} songs';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: nearbyService,
        builder: (context, _) {
          final phones = nearbyService.phones;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send ${_what()}', style: displayStyle(20), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('Phones with SpotVault open on the same Wi-Fi show up here.', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 12),
                if (nearbyService.scanning && phones.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                else if (phones.isEmpty)
                  _NoPhones(onRetry: nearbyService.discover)
                else
                  for (final p in phones)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                          backgroundColor: kAccent.withValues(alpha: 0.15), child: Icon(Icons.smartphone_rounded, color: kAccent)),
                      title: Text(p.name),
                      subtitle: Text(sendingTo == p.id ? 'Waiting for them to accept…' : 'Tap to send',
                          style: TextStyle(color: kMuted, fontSize: 12)),
                      trailing: sendingTo == p.id
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.send_rounded, color: kAccent),
                      onTap: sendingTo == null ? () => _send(p) : null,
                    ),
                if (phones.isNotEmpty && nearbyService.scanning) const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 8),
                _NameRow(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NoPhones extends StatelessWidget {
  final VoidCallback onRetry;
  const _NoPhones({required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(children: [
          Icon(Icons.wifi_find_rounded, color: kMuted, size: 36),
          const SizedBox(height: 8),
          Text('No phones found. Open SpotVault on the other phone, on the same Wi-Fi (or its hotspot).',
              textAlign: TextAlign.center, style: TextStyle(color: kMuted)),
          TextButton(onPressed: onRetry, child: const Text('Look again')),
        ]),
      );
}

/// "Your name: iPhone 4F2 · Change".
class _NameRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.badge_outlined, size: 18, color: kMuted),
        const SizedBox(width: 8),
        Expanded(child: Text('Others see you as ${store.deviceName}', style: TextStyle(color: kMuted, fontSize: 12))),
        TextButton(
          onPressed: () async {
            final name = await askPlaylistName(context, title: 'Your name', initial: store.deviceName, action: 'Save');
            if (name != null) {
              store.deviceName = name.length > 30 ? name.substring(0, 30) : name;
              store.changed();
              nearbyService.changed();
            }
          },
          child: const Text('Change'),
        ),
      ]);
}

// ============================================================ prompts
/// Shown when another phone wants to send songs.
Future<bool> askIncomingShare(IncomingShare s) async {
  final ctx = navKey.currentContext;
  if (ctx == null) return false;
  final what = s.playlistName != null
      ? 'the playlist "${s.playlistName}" (${s.songs.length} songs)'
      : s.songs.length == 1
          ? '"${s.songs.first.title}"'
          : '${s.songs.length} songs';
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      icon: Icon(Icons.download_for_offline_rounded, color: kAccent, size: 36),
      title: Text('${s.fromName} wants to send you $what'),
      content: Text('They\'ll be saved on this phone${s.playlistName == null ? ' in "Shared with me"' : ''}.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Decline')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Accept')),
      ],
    ),
  );
  return ok == true;
}

/// Shown on the Jam host when someone wants to join.
Future<bool> askJoin(JoinRequest r) async {
  final ctx = navKey.currentContext;
  if (ctx == null) return false;
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      icon: Icon(Icons.groups_rounded, color: kAccent, size: 36),
      title: Text('${r.name} wants to join your Jam'),
      content: const Text('They can add songs and control what plays.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Let them in')),
      ],
    ),
  );
  return ok == true;
}

// ============================================================ Jam
void openJam(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JamScreen()));
}

class JamScreen extends StatefulWidget {
  const JamScreen({super.key});

  @override
  State<JamScreen> createState() => _JamScreenState();
}

class _JamScreenState extends State<JamScreen> {
  String? joining;
  final addrCtrl = TextEditingController();
  List<String> myAddresses = [];

  @override
  void initState() {
    super.initState();
    if (!nearbyService.inJam) nearbyService.discover();
    nearbyService.myAddresses().then((a) {
      if (mounted) setState(() => myAddresses = a);
    });
  }

  @override
  void dispose() {
    addrCtrl.dispose();
    super.dispose();
  }

  Future<void> _join(NearbyPhone p) async {
    setState(() => joining = p.id);
    final err = await nearbyService.joinJam(p);
    if (!mounted) return;
    setState(() => joining = null);
    if (err != null) toast(context, err);
  }

  /// "Join by address": 192.168.1.23 or 192.168.1.23:50510.
  Future<void> _joinByAddress() async {
    FocusScope.of(context).unfocus();
    final text = addrCtrl.text.trim();
    final m = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{2,5}))?$').firstMatch(text);
    if (m == null) {
      toast(context, 'Type the address shown on the other phone, like 192.168.1.23');
      return;
    }
    setState(() => joining = 'address');
    final phone = await nearbyService.hello(m.group(1)!, int.tryParse(m.group(2) ?? '') ?? kNearbyPort);
    if (!mounted) return;
    if (phone == null) {
      setState(() => joining = null);
      toast(context, 'No SpotVault at $text. Check the address and that both are on the same Wi-Fi.');
      return;
    }
    if (phone.jam == null) {
      setState(() => joining = null);
      toast(context, '${phone.name} hasn\'t started a Jam yet.');
      return;
    }
    await _join(phone);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([nearbyService, playerService]),
      builder: (context, _) {
        final n = nearbyService;
        return Scaffold(
          appBar: AppBar(
            title: Text(n.jamHost != null
                ? 'Your Jam'
                : n.jamGuest != null
                    ? "${n.jamGuest!.hostName}'s Jam"
                    : 'Jam'),
            backgroundColor: Colors.transparent,
          ),
          body: n.inJam ? _inJam(n) : _start(n),
        );
      },
    );
  }

  // ---------------------------------------------------------------- not in a Jam
  Widget _start(NearbyService n) {
    final jams = n.phones.where((p) => p.jam != null).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
      children: [
        Text('Play together on the same Wi-Fi. No internet needed.', style: TextStyle(color: kMuted)),
        const SizedBox(height: 16),
        _ModeCard(
          icon: Icons.speaker_rounded,
          title: 'Be the speaker',
          text: 'This phone plays (plug it into a speaker). Friends add songs from their phones and control the music.',
          onTap: () => n.startJam(JamMode.speaker),
        ),
        const SizedBox(height: 10),
        _ModeCard(
          icon: Icons.headphones_rounded,
          title: 'Everyone in sync',
          text: 'Every phone plays the same song at the same moment, each on its own speaker or earphones.',
          onTap: () => n.startJam(JamMode.sync),
        ),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(child: Text('Join a Jam nearby', style: displayStyle(18))),
          n.scanning
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton.icon(onPressed: n.discover, icon: const Icon(Icons.refresh_rounded), label: const Text('Look')),
        ]),
        if (jams.isEmpty && !n.scanning)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No Jams yet. Ask your friend to start one, then tap Look.', style: TextStyle(color: kMuted)),
          ),
        for (final p in jams)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(backgroundColor: kAccent.withValues(alpha: 0.15), child: Icon(Icons.groups_rounded, color: kAccent)),
            title: Text('${p.jam!['title'] ?? p.name}'),
            subtitle: Text(
              '${p.jam!['mode'] == 'sync' ? 'Everyone in sync' : 'Speaker'} · ${p.jam!['guests'] ?? 0} joined'
              '${joining == p.id ? ' · waiting for them to let you in…' : ''}',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            trailing: joining == p.id
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton(
                    onPressed: joining != null ? null : () => _join(p),
                    child: const Text('Join'),
                  ),
          ),
        const SizedBox(height: 18),
        Text('Join by address', style: displayStyle(18)),
        const SizedBox(height: 4),
        Text("If the Jam doesn't show up, type the address shown on the other phone's Jam screen.",
            style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: addrCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _joinByAddress(),
              decoration: const InputDecoration(isDense: true, hintText: 'e.g. 192.168.1.23', prefixIcon: Icon(Icons.lan_outlined)),
            ),
          ),
          const SizedBox(width: 10),
          joining == 'address'
              ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton(onPressed: joining != null ? null : _joinByAddress, child: const Text('Join')),
        ]),
        const SizedBox(height: 16),
        _MyAddress(addresses: myAddresses),
        const SizedBox(height: 8),
        _NameRow(),
      ],
    );
  }

  // ---------------------------------------------------------------- in a Jam
  Widget _inJam(NearbyService n) {
    final host = n.jamHost;
    final guest = n.jamGuest;
    final mode = host?.mode ?? guest!.mode;
    final List<Map<String, dynamic>> queue = host != null ? [for (final i in host.items) i.toJson()] : guest!.queue;
    final currentKey = host != null ? (playerService.current?.id.replaceFirst('jam:', '')) : guest!.state['current'] as String?;
    final playing = host != null ? playerService.player.playing : guest!.state['playing'] == true;
    final people = host != null ? host.guests.values.toList() : List<String>.from(guest!.state['guests'] as List? ?? const []);
    final cur = queue.where((q) => q['key'] == currentKey).firstOrNull;

    Future<void> control(String action, {int? index}) async {
      try {
        if (host != null) {
          await host.control(action, index: index);
        } else {
          await guest!.control(action, index: index);
        }
      } catch (_) {
        if (mounted) toast(context, "Couldn't reach the Jam");
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(mode == JamMode.sync ? Icons.headphones_rounded : Icons.speaker_rounded, color: kAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  mode == JamMode.sync
                      ? 'Everyone in sync'
                      : host != null
                          ? 'This phone is the speaker'
                          : '${guest!.hostName} is the speaker',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              people.isEmpty
                  ? (host != null ? 'Waiting for friends. They tap Jam → Join on their phone.' : '')
                  : 'With ${people.join(', ')}',
              style: TextStyle(color: kMuted, fontSize: 13),
            ),
            if (host != null) ...[
              const SizedBox(height: 8),
              _MyAddress(addresses: myAddresses, compact: true),
            ],
            if (guest?.error != null) Text(guest!.error!, style: TextStyle(color: pal.danger, fontSize: 13)),
            const SizedBox(height: 14),
            Text(cur == null ? 'Nothing playing yet' : '${cur['title']}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: displayStyle(20)),
            if (cur != null)
              Text('${cur['artist']} · added by ${cur['by']}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted)),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                  iconSize: 36, tooltip: 'Previous', icon: const Icon(Icons.skip_previous_rounded), onPressed: () => control('previous')),
              const SizedBox(width: 10),
              IconButton.filled(
                iconSize: 40,
                tooltip: playing ? 'Pause' : 'Play',
                style: IconButton.styleFrom(backgroundColor: kViolet, foregroundColor: Colors.white),
                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                onPressed: () => control(playing ? 'pause' : 'play'),
              ),
              const SizedBox(width: 10),
              IconButton(iconSize: 36, tooltip: 'Next', icon: const Icon(Icons.skip_next_rounded), onPressed: () => control('next')),
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('Up next', style: displayStyle(18))),
          FilledButton.icon(
            onPressed: () => _addSongs(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add songs'),
          ),
        ]),
        const SizedBox(height: 6),
        if (queue.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('Add songs from your phone to start the music.', style: TextStyle(color: kMuted)),
          ),
        for (var i = 0; i < queue.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: queue[i]['key'] == currentKey
                ? Icon(Icons.graphic_eq_rounded, color: kAccent)
                : queue[i]['failed'] == true
                    ? Icon(Icons.error_outline_rounded, color: pal.danger)
                    : queue[i]['ready'] == true
                        ? Icon(Icons.music_note_rounded, color: kMuted)
                        : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('${queue[i]['title']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: queue[i]['key'] == currentKey ? FontWeight.w800 : FontWeight.w500)),
            subtitle: Text('${queue[i]['artist']} · ${queue[i]['by']}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 12)),
            onTap: queue[i]['ready'] == true ? () => control('jump', index: i) : null,
          ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: pal.danger),
          onPressed: () async {
            await n.leaveJam();
            if (mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.logout_rounded),
          label: Text(host != null ? 'End Jam' : 'Leave Jam'),
        ),
      ],
    );
  }

  Future<void> _addSongs(BuildContext context) async {
    final picked = await pickSongs(context);
    if (picked == null || picked.$1.isEmpty) return;
    try {
      if (nearbyService.jamHost != null) {
        nearbyService.jamHost!.addOwn(picked.$1, next: picked.$2);
      } else {
        await nearbyService.jamGuest!.add(picked.$1, next: picked.$2);
      }
      if (context.mounted) toast(context, 'Added ${picked.$1.length} song${picked.$1.length == 1 ? '' : 's'}');
    } catch (_) {
      if (context.mounted) toast(context, "Couldn't reach the Jam");
    }
  }
}

/// "Your address: 192.168.1.23" with a copy button, for "Join by address".
class _MyAddress extends StatelessWidget {
  final List<String> addresses;
  final bool compact;
  const _MyAddress({required this.addresses, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (addresses.isEmpty) {
      return Text(compact ? '' : 'Connect to Wi-Fi to see your address.', style: TextStyle(color: kMuted, fontSize: 12));
    }
    final a = addresses.first;
    return Row(children: [
      Icon(Icons.lan_outlined, size: 18, color: kMuted),
      const SizedBox(width: 8),
      Expanded(
        child: Text.rich(TextSpan(children: [
          TextSpan(text: 'Your address: ', style: TextStyle(color: kMuted, fontSize: 13)),
          TextSpan(text: a, style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w800)),
        ])),
      ),
      IconButton(
        tooltip: 'Copy address',
        icon: const Icon(Icons.copy_rounded, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: a));
          toast(context, 'Address copied');
        },
      ),
    ]);
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;
  const _ModeCard({required this.icon, required this.title, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: GlassCard(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(gradient: kBrandGradient, borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 2),
                Text(text, style: TextStyle(color: kMuted, fontSize: 13, height: 1.3)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: kMuted),
          ]),
        ),
      );
}

/// Pick songs from this phone's library. Returns (songs, playNext).
Future<(List<Track>, bool)?> pickSongs(BuildContext context) {
  return showModalBottomSheet<(List<Track>, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (_, scroll) => _SongPicker(scroll: scroll),
    ),
  );
}

class _SongPicker extends StatefulWidget {
  final ScrollController scroll;
  const _SongPicker({required this.scroll});

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  String q = '';
  PlaylistInfo? playlist;
  final Set<String> chosen = {};

  @override
  Widget build(BuildContext context) {
    final all = playlist != null ? store.tracksOf(playlist!) : LibraryStore.sortTracks(store.tracks.values.toList(), TrackSort.title);
    final list = q.isEmpty ? all : all.where((t) => t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q)).toList();
    final picked = [
      for (final id in chosen)
        if (store.tracks[id] != null) store.tracks[id]!
    ];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => q = v.toLowerCase().trim()),
          decoration: const InputDecoration(isDense: true, hintText: 'Find songs on this phone', prefixIcon: Icon(Icons.search)),
        ),
      ),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child:
                ChoiceChip(label: const Text('All songs'), selected: playlist == null, onSelected: (_) => setState(() => playlist = null)),
          ),
          for (final p in store.sortedPlaylists)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child:
                  ChoiceChip(label: Text(p.name), selected: playlist?.folder == p.folder, onSelected: (_) => setState(() => playlist = p)),
            ),
        ]),
      ),
      if (playlist != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() {
              final ids = list.map((t) => t.id);
              chosen.containsAll(ids) ? chosen.removeAll(ids) : chosen.addAll(ids);
            }),
            child: Text(chosen.containsAll(list.map((t) => t.id)) ? 'Clear these' : 'Select all ${list.length}'),
          ),
        ),
      Expanded(
        child: ListView.builder(
          controller: widget.scroll,
          itemCount: list.length,
          itemBuilder: (_, i) {
            final t = list[i];
            final on = chosen.contains(t.id);
            return CheckboxListTile(
              value: on,
              onChanged: (_) => setState(() => on ? chosen.remove(t.id) : chosen.add(t.id)),
              secondary: TrackArt(t, size: 42),
              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 12)),
            );
          },
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(context, (picked, true)),
                child: const Text('Play next'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(context, (picked, false)),
                child: Text(picked.isEmpty ? 'Add' : 'Add ${picked.length}'),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

/// Home card while in a Jam or while songs arrive from another phone.
class NearbyStatusCard extends StatelessWidget {
  const NearbyStatusCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: nearbyService,
      builder: (context, _) {
        final n = nearbyService;
        final rows = <Widget>[];
        if (n.receiving != null) {
          rows.add(ListTile(
            leading: n.receiveTotal > 0 && n.receiveDone < n.receiveTotal
                ? SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.5, value: n.receiveDone / n.receiveTotal),
                  )
                : Icon(Icons.download_done_rounded, color: kAccent),
            title: Text(n.receiving!, style: const TextStyle(fontSize: 14)),
            subtitle: n.receiveTotal > 0 ? Text('${n.receiveDone} of ${n.receiveTotal}', style: TextStyle(color: kMuted)) : null,
          ));
        }
        if (n.inJam) {
          rows.add(ListTile(
            leading: Icon(Icons.groups_rounded, color: kAccent),
            title: Text(n.jamHost != null ? 'Your Jam is on' : "You're in ${n.jamGuest!.hostName}'s Jam",
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('Tap to see the queue and add songs', style: TextStyle(color: kMuted, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => openJam(context),
          ));
        }
        if (rows.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: GlassCard(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: rows)),
        );
      },
    );
  }
}
