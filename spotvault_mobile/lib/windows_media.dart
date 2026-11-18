import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'library_store.dart';
import 'player_service.dart';

/// Windows only: tells Windows what SpotVault is playing (System Media Transport
/// Controls), so it shows in the Win+A media box and the lock screen, the
/// keyboard media keys work, and apps that read media sessions can see it.
/// The native side is windows/runner/smtc.cpp. Playback itself is unchanged.
class WindowsMedia {
  WindowsMedia(this._ps, this._store);

  final PlayerService _ps;
  final LibraryStore _store;
  static const _channel = MethodChannel('spotvault/smtc');

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _tick;
  String? _shownKey; // the song Windows is showing, so it's only sent once per change
  String _lastStatus = '';

  void start() {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler(_onCall);
    final p = _ps.player;
    _subs
      ..add(p.sequenceStateStream.listen((_) => _sync()))
      ..add(p.playerStateStream.listen((_) => _sync()))
      ..add(p.positionDiscontinuityStream.listen((_) => _sendState(force: true)));
    // Windows draws its own progress bar; keep it in step while playing.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (p.playing) _sendState(force: true);
    });
    _sync();
  }

  Future<void> dispose() async {
    _tick?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _invoke('clear');
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final p = _ps.player;
    switch (call.method) {
      case 'onButton':
        switch (call.arguments) {
          case 'play':
            p.play();
          case 'pause' || 'stop':
            p.pause();
          case 'next':
            await _ps.next();
          case 'previous':
            await _ps.previous();
        }
      case 'onSeek':
        final ms = (call.arguments as num).toInt();
        await p.seek(Duration(milliseconds: ms));
    }
  }

  /// The song now playing: its title and artist from the player's own list
  /// (this covers previews and online songs too), its cover from the library.
  void _sync() {
    final p = _ps.player;
    final seq = p.sequence;
    final i = p.currentIndex;
    if (seq.isEmpty || i == null || i < 0 || i >= seq.length) {
      if (_shownKey != null) {
        _shownKey = null;
        _lastStatus = '';
        _invoke('clear');
      }
      return;
    }
    final tag = seq[i].tag;
    if (tag is! MediaItem) return;
    final track = _ps.trackById(tag.id);
    final key = '$i:${tag.id}';
    if (key != _shownKey) {
      _shownKey = key;
      final art = track == null ? null : _store.artFor(track);
      _invoke('update', {
        'title': track?.title ?? tag.title,
        'artist': track?.artist ?? tag.artist ?? '',
        'album': track?.album.isNotEmpty == true ? track!.album : (track?.folder ?? tag.album ?? ''),
        'art': art != null && art.existsSync() ? art.absolute.path : '',
      });
    }
    _sendState();
  }

  void _sendState({bool force = false}) {
    if (_shownKey == null) return;
    final p = _ps.player;
    final done = p.processingState == ProcessingState.completed;
    final status = done ? 'stopped' : (p.playing ? 'playing' : 'paused');
    if (!force && status == _lastStatus) return;
    _lastStatus = status;
    _invoke('state', {
      'status': status,
      'position': p.position.inMilliseconds,
      'duration': (p.duration ?? Duration.zero).inMilliseconds,
    });
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('media controls: $e');
    }
  }
}
