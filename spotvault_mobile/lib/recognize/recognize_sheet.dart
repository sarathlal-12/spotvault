import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_state.dart';
import '../ui/trending_view.dart' show TrendingBackend, songKey;
import 'shazam_client.dart';

/// Records a few seconds of audio as 16 kHz mono PCM (native code per platform).
class AudioListen {
  static const _ch = MethodChannel('spotvault/capture');

  /// Windows and Android can hear what the device itself is playing; iPhones
  /// only have the microphone.
  static bool get canHearDevice => Platform.isWindows || Platform.isAndroid;

  static Future<Int16List> record({required bool device, int ms = 10000}) async {
    if (Platform.isAndroid) {
      final ok = await Permission.microphone.request();
      if (!ok.isGranted) throw RecognizeException('SpotVault needs the microphone permission to listen.');
    }
    try {
      final bytes = await _ch.invokeMethod<Uint8List>('record', {'source': device ? 'system' : 'mic', 'ms': ms});
      if (bytes == null || bytes.length < 2) throw RecognizeException("Couldn't hear anything. Try again.");
      // A fresh copy: the channel's bytes may start at an odd offset.
      final copy = Uint8List.fromList(bytes);
      return Int16List.view(copy.buffer, 0, copy.length ~/ 2);
    } on PlatformException catch (e) {
      throw RecognizeException(e.message ?? "Couldn't listen. Try again.");
    }
  }
}

/// "What's this song?": listens to the device or the microphone, asks Shazam,
/// then offers Listen and Save like the Trending list.
Future<void> showRecognizeSheet(BuildContext context, TrendingBackend backend) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _RecognizeSheet(backend),
    );

/// The header button that opens it.
class RecognizeButton extends StatelessWidget {
  final TrendingBackend backend;
  const RecognizeButton({super.key, required this.backend});

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
        tooltip: "What's this song?",
        onPressed: () => showRecognizeSheet(context, backend),
        icon: const Icon(Icons.graphic_eq_rounded),
      );
}

enum _Stage { pick, listening, thinking, found, none, error }

class _RecognizeSheet extends StatefulWidget {
  final TrendingBackend backend;
  const _RecognizeSheet(this.backend);

  @override
  State<_RecognizeSheet> createState() => _RecognizeSheetState();
}

class _RecognizeSheetState extends State<_RecognizeSheet> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  _Stage stage = _Stage.pick;
  String error = '';
  RecognizedSong? song;
  bool lastDevice = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _listen(bool device) async {
    lastDevice = device;
    setState(() => stage = _Stage.listening);
    try {
      final pcm = await AudioListen.record(device: device);
      if (!mounted) return;
      setState(() => stage = _Stage.thinking);
      final s = await ShazamClient.recognize(pcm);
      if (!mounted) return;
      setState(() {
        song = s;
        stage = s == null ? _Stage.none : _Stage.found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = '$e';
        stage = _Stage.error;
      });
    }
  }

  Map<String, dynamic> get _asSong => {'title': song!.title, 'artist': song!.artist, 'url': '', 'art': song!.cover};

  Future<void> _play() async {
    final s = _asSong;
    final key = songKey(s);
    if (playerService.previewing && playerService.previewKey == key) {
      await playerService.stopPreview();
      return;
    }
    try {
      final uri = await widget.backend.previewUri(s);
      await playerService.playPreview(uri, key: key, title: song!.title, artist: song!.artist, artUrl: song!.cover);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't play it: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final deviceLabel = Platform.isWindows ? "What's playing on this PC" : "What's playing on this phone";
    Widget body;
    switch (stage) {
      case _Stage.pick:
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text("Find out what song is playing. SpotVault listens for 10 seconds.", style: TextStyle(color: p.muted)),
          const SizedBox(height: 18),
          if (AudioListen.canHearDevice) ...[
            FilledButton.icon(
              onPressed: () => _listen(true),
              icon: Icon(Platform.isWindows ? Icons.desktop_windows_rounded : Icons.smartphone_rounded),
              label: Text(deviceLabel),
            ),
            const SizedBox(height: 4),
            Text(Platform.isWindows ? 'Hears the PC\'s sound directly: a video, a browser tab, another app.' : 'Android asks to allow it. Some apps block this.',
                textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 12)),
            const SizedBox(height: 12),
          ],
          (AudioListen.canHearDevice ? OutlinedButton.icon : FilledButton.icon)(
            onPressed: () => _listen(false),
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Listen with the microphone'),
          ),
          const SizedBox(height: 4),
          Text('For music playing near you.', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 12)),
        ]);
      case _Stage.listening:
      case _Stage.thinking:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => Container(
              width: 110 + 20 * _pulse.value,
              height: 110 + 20 * _pulse.value,
              decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent.withValues(alpha: 0.12 + 0.1 * _pulse.value)),
              child: Icon(stage == _Stage.listening ? Icons.graphic_eq_rounded : Icons.search_rounded, size: 46, color: p.accent),
            ),
          ),
          const SizedBox(height: 16),
          Text(stage == _Stage.listening ? 'Listening…' : 'Finding the song…', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(stage == _Stage.listening ? 'Keep the music playing for 10 seconds.' : 'Asking Shazam.', style: TextStyle(color: p.muted)),
        ]);
      case _Stage.found:
        final s = song!;
        final playing = playerService.previewing && playerService.previewKey == songKey(_asSong);
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: 160,
              height: 160,
              child: s.cover.isEmpty
                  ? Container(color: p.card, child: Icon(Icons.music_note_rounded, size: 50, color: p.muted))
                  : Image.network(s.cover, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: p.card)),
            ),
          ),
          const SizedBox(height: 14),
          Text(s.title, textAlign: TextAlign.center, style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(s.artist, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _play,
                icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
                label: Text(playing ? 'Stop' : 'Listen'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => widget.backend.save(context, _asSong),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Save'),
              ),
            ),
          ]),
          TextButton(onPressed: () => setState(() => stage = _Stage.pick), child: const Text('Find another song')),
        ]);
      case _Stage.none:
      case _Stage.error:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(stage == _Stage.none ? Icons.help_outline_rounded : Icons.error_outline_rounded, size: 46, color: p.muted),
          const SizedBox(height: 10),
          Text(stage == _Stage.none ? "Couldn't recognise this song." : error, textAlign: TextAlign.center, style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
          if (stage == _Stage.none) ...[
            const SizedBox(height: 4),
            Text('Try again where the music is louder, or during the chorus.', textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: () => _listen(lastDevice), icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
          TextButton(onPressed: () => setState(() => stage = _Stage.pick), child: const Text('Back')),
        ]);
    }
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text("What's this song?", style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            body,
          ]),
        ),
      ),
    );
  }
}
