import 'qr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../pc_link.dart';
import '../sync_service.dart';
import '../update_service.dart';
import 'aurora.dart';
import 'dupes_screen.dart';
import 'update_ui.dart';

/// Sync tab: one big Sync button, what's downloading right now, and
/// everything else tucked under "More".
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final hostCtrl = TextEditingController(text: store.lastHost);
  late final pinCtrl = TextEditingController(text: store.pin);
  int? storageBytes;
  bool editingPc = false;

  bool get paired => store.lastHost.isNotEmpty && store.pin.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _refreshStorage();
    if (store.lastHost.isEmpty) syncService.discover().then(_autofill);
  }

  @override
  void dispose() {
    hostCtrl.dispose();
    pinCtrl.dispose();
    super.dispose();
  }

  void _autofill(List<FoundPc> pcs) {
    if (!mounted || pcs.isEmpty || hostCtrl.text.isNotEmpty) return;
    setState(() => hostCtrl.text = _hostText(pcs.first));
  }

  String _hostText(FoundPc pc) => pc.port == kHttpPort ? pc.host : '${pc.host}:${pc.port}';

  Future<void> _refreshStorage() async {
    final b = await store.storageBytes();
    if (mounted) setState(() => storageBytes = b);
  }

  Future<void> _sync() async {
    FocusScope.of(context).unfocus();
    final host = editingPc || !paired ? hostCtrl.text : store.lastHost;
    final pin = (editingPc || !paired ? pinCtrl.text : store.pin).replaceAll(RegExp(r'\D'), '');
    await syncService.sync(host, pin);
    await playerService.refreshAfterSync();
    if (mounted && syncService.state == SyncState.done) setState(() => editingPc = false);
    _refreshStorage();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([syncService, pcLink, store]),
      builder: (context, _) {
        final s = syncService;
        return SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Row(
                children: [
                  Expanded(child: Text('Sync', style: displayStyle(28))),
                  const ThemeToggle(),
                ],
              ),
              const SizedBox(height: 14),
              _syncCard(s),
              const SizedBox(height: 12),
              _DownloadsCard(jobs: pcLink.jobs.reversed.toList(), syncing: s.busy ? s.active.toList() : const []),
              const SizedBox(height: 12),
              _statsLine(),
              const SizedBox(height: 12),
              _moreCard(s),
              const SizedBox(height: 180),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- main card
  Widget _syncCard(SyncService s) {
    final showFields = !paired || editingPc;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.laptop_windows_rounded, color: kAccent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(paired ? (store.pcName.isEmpty ? 'Your PC' : store.pcName) : 'Connect your PC',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    Text(
                      paired
                          ? (store.lastSync == 0
                              ? 'Not synced yet'
                              : 'Last sync ${_ago(DateTime.fromMillisecondsSinceEpoch(store.lastSync))}')
                          : 'Open SpotVault on your PC and click "Connect phone". Same Wi-Fi.',
                      style: TextStyle(color: kMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showFields) ...[
            const SizedBox(height: 12),
            if (s.found.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final pc in s.found)
                    ChoiceChip(
                      label: Text(pc.name),
                      selected: hostCtrl.text == _hostText(pc),
                      onSelected: (_) => setState(() => hostCtrl.text = _hostText(pc)),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), shape: const StadiumBorder()),
              onPressed: s.busy
                  ? null
                  : () async {
                      final link = await scanSpotLink(context);
                      if (link == null || !mounted) return;
                      if (link.kind != 'pc') {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That is a Jam code. Open Jam to use it.')));
                        return;
                      }
                      setState(() {
                        hostCtrl.text = link.port == 50505 ? link.host : '${link.host}:${link.port}';
                        pinCtrl.text = link.pin;
                      });
                      _sync();
                    },
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text("Scan the code on your PC"),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: hostCtrl,
              enabled: !s.busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'PC address',
                hintText: 'e.g. 192.168.0.113',
                prefixIcon: const Icon(Icons.lan_outlined),
                suffixIcon: s.scanning
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(
                        tooltip: 'Find PCs on this Wi-Fi',
                        icon: const Icon(Icons.wifi_find),
                        onPressed: s.busy ? null : () => s.discover().then(_autofill),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pinCtrl,
              enabled: !s.busy,
              keyboardType: TextInputType.number,
              maxLength: 7,
              decoration: const InputDecoration(
                labelText: 'PIN',
                hintText: 'Shown in the Connect phone window',
                prefixIcon: Icon(Icons.pin_outlined),
                counterText: '',
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (s.state != SyncState.idle && s.state != SyncState.done) _Progress(s),
          if (s.state == SyncState.done)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                const Icon(Icons.check_circle_rounded, color: kCyan, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(s.message, style: TextStyle(color: kMuted, fontSize: 13))),
              ]),
            ),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: s.busy
                ? OutlinedButton.icon(onPressed: s.cancel, icon: const Icon(Icons.stop_rounded), label: const Text('Stop'))
                : GradientButton(icon: Icons.sync_rounded, label: paired && !editingPc ? 'Sync with PC' : 'Connect and sync', onTap: _sync),
          ),
        ],
      ),
    );
  }

  Widget _statsLine() {
    final parts = [
      '${store.tracks.length} songs',
      '${store.playlists.length} playlists',
      if (storageBytes != null) formatBytes(storageBytes!),
    ];
    return Text(parts.join('  ·  '), textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 12));
  }

  // ---------------------------------------------------------------- More
  Widget _moreCard(SyncService s) {
    return _Card(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: const Text('More', style: TextStyle(fontWeight: FontWeight.w700)),
          children: [
            if (paired)
              _MoreTile(
                icon: Icons.swap_horiz_rounded,
                title: 'Change PC',
                subtitle: '${store.lastHost} · PIN ${store.pin.isEmpty ? '—' : '••••'}',
                onTap: s.busy ? null : () => setState(() => editingPc = !editingPc),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: store.mirrorDeletes,
              onChanged: s.busy ? null : store.setMirrorDeletes,
              title: const Text('Remove songs deleted on PC'),
              subtitle: Text('Songs you saved on the phone are always kept', style: TextStyle(color: kMuted, fontSize: 12)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: !pcLink.onPhone,
              onChanged: (v) => pcLink.setUseBridge(v),
              title: const Text('Download new songs on my PC'),
              subtitle: Text('Off: the phone downloads songs itself', style: TextStyle(color: kMuted, fontSize: 12)),
            ),
            if (store.excludedTracks.isNotEmpty || store.excludedFolders.isNotEmpty)
              _MoreTile(
                icon: Icons.restore_rounded,
                title: 'Bring back removed songs',
                subtitle: '${store.excludedTracks.length} songs, ${store.excludedFolders.length} playlists come back at the next sync',
                onTap: () {
                  store.restoreHidden();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('They come back at your next sync')));
                },
              ),
            _MoreTile(
              icon: Icons.cleaning_services_outlined,
              title: 'Clean up duplicates',
              subtitle: 'Songs saved on this phone more than once',
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DupesScreen()));
                _refreshStorage();
              },
            ),
            _MoreTile(
              icon: Icons.receipt_long_rounded,
              title: 'Downloader log',
              subtitle: 'What happened with recent downloads',
              onTap: () => _showLog(context),
            ),
            _MoreTile(
              icon: Icons.system_update_alt_rounded,
              title: 'Check for updates',
              subtitle: 'You have v$kAppVersion',
              onTap: () => runUpdateCheck(context, manual: true),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLog(BuildContext context) async {
    final text = await pcLink.engineLog();
    if (!context.mounted) return;
    final lines = text.trim().split('\n');
    final shown = lines.length > 300 ? lines.sublist(lines.length - 300).join('\n') : text.trim();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(children: [
                  const Expanded(child: Text('Downloader log', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  TextButton.icon(
                    onPressed: shown.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: shown));
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied')));
                          },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy'),
                  ),
                ]),
              ),
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text('Nothing yet. Save a song from Search first.', style: TextStyle(color: kMuted)))
                    : SingleChildScrollView(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        child: SelectableText(shown, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4)),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
  }
}

/// Songs downloading right now: phone saves and files copying from the PC.
class _DownloadsCard extends StatelessWidget {
  final List<DlJob> jobs;
  final List<String> syncing;
  const _DownloadsCard({required this.jobs, required this.syncing});

  @override
  Widget build(BuildContext context) {
    final active = jobs.where((j) => !j.finished).toList();
    final recent = jobs.where((j) => j.finished).take(3).toList();
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: Text('Downloads', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            if (recent.isNotEmpty) TextButton(onPressed: pcLink.clearFinished, child: const Text('Clear')),
          ]),
          if (active.isEmpty && syncing.isEmpty && recent.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Nothing downloading. Songs you save from Search show up here.', style: TextStyle(color: kMuted, fontSize: 13)),
            ),
          for (final name in syncing) _JobRow(title: name, message: 'Copying from PC', state: DlState.copying),
          for (final j in active) _JobRow(title: j.song.title, message: j.message, state: j.state),
          for (final j in recent) _JobRow(title: j.song.title, message: j.message, state: j.state),
        ],
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  final String title;
  final String message;
  final DlState state;
  const _JobRow({required this.title, required this.message, required this.state});

  @override
  Widget build(BuildContext context) {
    final icon = switch (state) {
      DlState.saved => const Icon(Icons.check_circle_rounded, color: kCyan, size: 20),
      DlState.failed => Icon(Icons.error_outline_rounded, color: pal.danger, size: 20),
      _ => SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: kAccent)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        icon,
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text(message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: state == DlState.failed ? pal.danger : kMuted)),
          ]),
        ),
      ]),
    );
  }
}

class _Progress extends StatelessWidget {
  final SyncService s;
  const _Progress(this.s);

  @override
  Widget build(BuildContext context) {
    final error = s.state == SyncState.error || s.state == SyncState.cancelled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.message, style: TextStyle(color: error ? pal.danger : kText, fontWeight: FontWeight.w600, fontSize: 13)),
          if (!error) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: s.state == SyncState.syncing && s.filesTotal > 0
                  ? TweenAnimationBuilder<double>(
                      tween: Tween(end: s.progress),
                      duration: const Duration(milliseconds: 300),
                      builder: (_, v, __) =>
                          LinearProgressIndicator(value: v.clamp(0.0, 1.0), minHeight: 6, color: kAccent, backgroundColor: pal.track),
                    )
                  : LinearProgressIndicator(minHeight: 6, color: kAccent, backgroundColor: pal.track),
            ),
            if (s.state == SyncState.syncing && s.filesTotal > 0) ...[
              const SizedBox(height: 6),
              Text('${s.filesDone} / ${s.filesTotal} songs · ${formatBytes(s.bytesDone)} of ${formatBytes(s.bytesTotal)}',
                  style: TextStyle(color: kMuted, fontSize: 12)),
            ],
          ],
        ],
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  const _MoreTile({required this.icon, required this.title, required this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: kAccent),
        title: Text(title),
        subtitle: Text(subtitle, style: TextStyle(color: kMuted, fontSize: 12)),
        trailing: Icon(Icons.chevron_right_rounded, color: kMuted),
        onTap: onTap,
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: pal.dark ? pal.glass : pal.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: kLine),
        ),
        // Material so list rows inside show their tap ripple.
        child: Material(type: MaterialType.transparency, child: child),
      );
}
