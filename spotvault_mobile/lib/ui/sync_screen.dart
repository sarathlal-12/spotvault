import 'package:flutter/material.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../sync_service.dart';
import '../update_service.dart';
import 'aurora.dart';
import 'update_ui.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final hostCtrl = TextEditingController(text: store.lastHost);
  late final pinCtrl = TextEditingController(text: store.pin);
  int? storageBytes;

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
    final pin = pinCtrl.text.replaceAll(RegExp(r'\D'), '');
    await syncService.sync(hostCtrl.text, pin);
    await playerService.refreshAfterSync();
    _refreshStorage();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: syncService,
      builder: (context, _) {
        final s = syncService;
        return SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Row(
                children: [
                  Expanded(child: Text('Sync from PC', style: displayStyle(28))),
                  const ThemeToggle(),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'On your PC, open SpotVault and click "Connect phone". Keep both devices on the same Wi-Fi.',
                style: TextStyle(color: kMuted),
              ),
              const SizedBox(height: 16),

              // ---- Found PCs
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('PCs on this Wi-Fi', style: TextStyle(fontWeight: FontWeight.bold))),
                        s.scanning
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : TextButton.icon(
                                onPressed: s.busy ? null : () => s.discover().then(_autofill),
                                icon: const Icon(Icons.wifi_find, size: 18),
                                label: const Text('Scan'),
                              ),
                      ],
                    ),
                    if (s.found.isEmpty && !s.scanning)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('None found. Type the address from your PC below.', style: TextStyle(color: kMuted, fontSize: 13)),
                      ),
                    for (final pc in s.found)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.laptop_windows, color: kAccent),
                        title: Text(pc.name),
                        subtitle: Text(_hostText(pc), style: TextStyle(color: kMuted)),
                        trailing: hostCtrl.text == _hostText(pc) ? Icon(Icons.check_circle, color: kAccent) : null,
                        onTap: () => setState(() => hostCtrl.text = _hostText(pc)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ---- Connection fields
              _Card(
                child: Column(
                  children: [
                    TextField(
                      controller: hostCtrl,
                      enabled: !s.busy,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'PC address',
                        hintText: 'e.g. 192.168.0.113',
                        prefixIcon: Icon(Icons.lan_outlined),
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
                        hintText: 'Shown in the Phone Sync window',
                        prefixIcon: Icon(Icons.pin_outlined),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: s.busy
                          ? OutlinedButton.icon(
                              onPressed: s.cancel,
                              icon: const Icon(Icons.stop),
                              label: const Text('Stop'),
                            )
                          : GradientButton(icon: Icons.sync_rounded, label: 'Sync now', onTap: _sync),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ---- Progress / result
              if (s.state != SyncState.idle) _ProgressCard(s),
              const SizedBox(height: 12),

              // ---- Settings & info
              _Card(
                child: Column(
                  children: [
                    ListenableBuilder(
                      listenable: store,
                      builder: (_, __) => SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: store.mirrorDeletes,
                        onChanged: s.busy ? null : store.setMirrorDeletes,
                        title: const Text('Remove songs deleted on PC'),
                        subtitle: Text('Keeps the phone an exact copy of your PC library', style: TextStyle(color: kMuted, fontSize: 12)),
                      ),
                    ),
                    const Divider(),
                    _InfoRow('Songs on phone', '${store.tracks.length}'),
                    _InfoRow('Playlists', '${store.playlists.length}'),
                    _InfoRow('Storage used', storageBytes == null ? '…' : formatBytes(storageBytes!)),
                    _InfoRow(
                      'Last sync',
                      store.lastSync == 0 ? 'Never' : _ago(DateTime.fromMillisecondsSinceEpoch(store.lastSync)),
                    ),
                    if (store.pcName.isNotEmpty) _InfoRow('PC', store.pcName),
                    const Divider(),
                    const _InfoRow('App version', 'v$kAppVersion'),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => runUpdateCheck(context, manual: true),
                        icon: const Icon(Icons.system_update_alt),
                        label: const Text('Check for updates'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 180),
            ],
          ),
        );
      },
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }
}

class _ProgressCard extends StatelessWidget {
  final SyncService s;
  const _ProgressCard(this.s);

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (s.state) {
      SyncState.done => (Icons.check_circle, kAccent),
      SyncState.error => (Icons.error, Colors.redAccent),
      SyncState.cancelled => (Icons.pause_circle, Colors.orangeAccent),
      _ => (Icons.sync, Colors.white),
    };
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Expanded(child: Text(s.message, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
            ],
          ),
          if (s.state == SyncState.syncing && s.filesTotal > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: s.progress),
                duration: const Duration(milliseconds: 400),
                builder: (_, v, __) => Stack(children: [
                  Container(height: 6, color: pal.track),
                  FractionallySizedBox(
                    widthFactor: v.clamp(0.0, 1.0),
                    child: Container(height: 6, decoration: const BoxDecoration(gradient: kBrandGradient)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${s.filesDone} / ${s.filesTotal} songs · ${formatBytes(s.bytesDone)} of ${formatBytes(s.bytesTotal)}',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            for (final name in s.active)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('↓ $name', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              ),
          ],
          if (s.state == SyncState.connecting) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(minHeight: 6, color: kAccent, backgroundColor: pal.track),
          ],
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: pal.dark ? pal.glass : pal.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: kLine),
        ),
        child: child,
      );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(color: kMuted))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
