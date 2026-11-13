import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'library_store.dart';

enum SleepMode { off, timer, endOfTrack }

/// Music player: queue, shuffle, repeat, sleep timer, resume where you left off.
/// Lock-screen and notification controls come from just_audio_background.
class PlayerService extends ChangeNotifier {
  final LibraryStore store;
  final AudioPlayer player = AudioPlayer();
  PlayerService(this.store);

  SleepMode sleepMode = SleepMode.off;
  DateTime? sleepAt;
  Timer? _sleepTimer;

  String? _lastCountedId;
  Timer? _saveTimer;
  Timer? _fadeTimer;

  // A-B Loop: repeat one part of the current song.
  Duration? loopA;
  Duration? loopB;
  bool get abActive => loopA != null && loopB != null;

  // Rewind: counts listening time while a song plays.
  Timer? _listenTimer;
  static const _listenTick = Duration(seconds: 5);

  /// How long Smart Sleep takes to fade the volume down.
  static const smartFade = Duration(seconds: 45);

  // Preview of an online song. The user's queue is set aside and put back after.
  bool previewing = false;
  String? previewKey;
  _Saved? _saved;

  Future<void> init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    // Pause when headphones are unplugged / Bluetooth disconnects.
    session.becomingNoisyEventStream.listen((_) => player.pause());

    player.currentIndexStream.listen((_) => _onTrackChanged());
    player.sequenceStateStream.listen((_) => notifyListeners());
    player.playerStateStream.listen((s) {
      notifyListeners();
      if (previewing && s.processingState == ProcessingState.completed) {
        stopPreview();
        return;
      }
      if (!s.playing) _persist();
    });
    player.errorStream.listen((e) => debugPrint('player error: $e'));

    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (player.playing) _persist();
    });

    _listenTimer = Timer.periodic(_listenTick, (_) {
      final t = current;
      if (player.playing && !previewing && t != null) {
        store.addListening(t, (_listenTick.inMilliseconds * player.speed).round());
      }
    });

    player.positionStream.listen((pos) {
      if (abActive && !previewing && pos >= loopB!) player.seek(loopA);
    });

    await _restore();
  }

  // ------------------------------------------------------------ state
  List<Track> get queue => [
        for (final s in player.sequence)
          if (store.tracks[(s.tag as MediaItem).id] != null) store.tracks[(s.tag as MediaItem).id]!
      ];

  Track? get current {
    final i = player.currentIndex;
    final seq = player.sequence;
    if (i == null || i < 0 || i >= seq.length) return null;
    return store.tracks[(seq[i].tag as MediaItem).id];
  }

  /// Queue in the order it will actually play (respects shuffle).
  List<int> get playOrder => player.shuffleModeEnabled ? player.shuffleIndices : List.generate(player.sequence.length, (i) => i);

  bool get hasQueue => player.sequence.isNotEmpty;

  // ------------------------------------------------------------ building sources
  AudioSource _source(Track t) {
    final art = store.artFor(t);
    return AudioSource.file(
      store.localFile(t).path,
      tag: MediaItem(
        id: t.id,
        title: t.title,
        artist: t.artist.isEmpty ? null : t.artist,
        album: t.album.isEmpty ? null : t.album,
        duration: t.duration > 0 ? t.length : null,
        artUri: art != null && art.existsSync() ? art.uri : null,
      ),
    );
  }

  List<Track> _playable(List<Track> tracks) => tracks.where((t) => store.localFile(t).existsSync()).toList();

  // ------------------------------------------------------------ actions
  Future<void> playTracks(List<Track> tracks, {int start = 0, bool? shuffle}) async {
    await _dropPreview();
    final startTrack = (start >= 0 && start < tracks.length) ? tracks[start] : null;
    final list = _playable(tracks);
    if (list.isEmpty) return;
    var index = startTrack == null ? 0 : list.indexWhere((t) => t.id == startTrack.id);
    if (index < 0) index = 0;

    if (shuffle != null) await player.setShuffleModeEnabled(shuffle);
    await player.setAudioSources([for (final t in list) _source(t)], initialIndex: index);
    if (shuffle == true) {
      await player.shuffle();
      // When shuffling a whole list, start from the first shuffled song.
      if (startTrack == null) await player.seek(Duration.zero, index: player.shuffleIndices.first);
    }
    player.play();
    _persist();
  }

  Future<void> playNext(Track t) async {
    if (previewing) await stopPreview();
    if (!hasQueue) return playTracks([t]);
    final i = (player.currentIndex ?? -1) + 1;
    await player.insertAudioSource(i, _source(t));
    _persist();
  }

  Future<void> addToQueue(Track t) async {
    if (previewing) await stopPreview();
    if (!hasQueue) return playTracks([t]);
    await player.addAudioSource(_source(t));
    _persist();
  }

  Future<void> removeAt(int index) async {
    await player.removeAudioSourceAt(index);
    _persist();
  }

  Future<void> move(int from, int to) async {
    await player.moveAudioSource(from, to);
    _persist();
  }

  Future<void> jumpTo(int index) async {
    await player.seek(Duration.zero, index: index);
    player.play();
  }

  void togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> previous() async {
    // Like most players: restart the song if more than 3 s in.
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  Future<void> next() => player.seekToNext();

  Future<void> toggleShuffle() async {
    final on = !player.shuffleModeEnabled;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
    _persist();
    notifyListeners();
  }

  Future<void> cycleLoop() async {
    final next = switch (player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await player.setLoopMode(next);
    _persist();
    notifyListeners();
  }

  Future<void> setSpeed(double s) async {
    await player.setSpeed(s);
    notifyListeners();
  }

  // ------------------------------------------------------------ sleep timer
  void setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _stopFade();
    if (d == null) {
      sleepMode = SleepMode.off;
      sleepAt = null;
    } else {
      sleepMode = SleepMode.timer;
      sleepAt = DateTime.now().add(d);
      // Smart Sleep: start fading before the end instead of a sudden stop.
      final fadeStart = store.smartSleep && d > smartFade ? d - smartFade : null;
      if (fadeStart != null) {
        _sleepTimer = Timer(fadeStart, () => _fadeOut(smartFade, _sleepNow));
      } else {
        _sleepTimer = Timer(d, _sleepNow);
      }
    }
    notifyListeners();
  }

  void _sleepNow() {
    _stopFade();
    player.pause();
    sleepMode = SleepMode.off;
    sleepAt = null;
    notifyListeners();
  }

  /// Lowers the volume step by step over [over], then calls [done].
  void _fadeOut(Duration over, void Function() done) {
    _stopFade();
    const steps = 30;
    var i = 0;
    _fadeTimer = Timer.periodic(over ~/ steps, (t) {
      i++;
      player.setVolume((1 - i / steps).clamp(0.0, 1.0));
      if (i >= steps) {
        t.cancel();
        done();
      }
    });
  }

  void _stopFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    player.setVolume(1);
  }

  void sleepAtEndOfTrack() {
    _sleepTimer?.cancel();
    _stopFade();
    sleepMode = SleepMode.endOfTrack;
    sleepAt = null;
    _watchEndOfTrack();
    notifyListeners();
  }

  StreamSubscription<Duration>? _endWatch;

  /// Smart Sleep with "end of song": fade during the last seconds of the song.
  void _watchEndOfTrack() {
    _endWatch?.cancel();
    if (!store.smartSleep) return;
    const fade = Duration(seconds: 12);
    _endWatch = player.positionStream.listen((pos) {
      final total = player.duration;
      if (sleepMode != SleepMode.endOfTrack) {
        _endWatch?.cancel();
        return;
      }
      if (total != null && total - pos <= fade && _fadeTimer == null && player.playing) {
        _fadeOut(total - pos, () {});
      }
    });
  }

  // ------------------------------------------------------------ A-B Loop
  /// First tap sets A, second sets B (and starts looping), third clears.
  void tapAbLoop() {
    final pos = player.position;
    if (loopA == null) {
      loopA = pos;
    } else if (loopB == null) {
      if (pos <= loopA! + const Duration(seconds: 1)) {
        loopA = pos; // B must come after A: treat it as a new A
      } else {
        loopB = pos;
        player.seek(loopA);
      }
    } else {
      clearAbLoop(notify: false);
    }
    notifyListeners();
  }

  void clearAbLoop({bool notify = true}) {
    loopA = null;
    loopB = null;
    if (notify) notifyListeners();
  }

  // ------------------------------------------------------------ preview
  /// Plays an online song from the PC. Call [stopPreview] to get the queue back.
  Future<void> playPreview(Uri uri, {required String key, required String title, String? artist, String? artUrl}) async {
    if (!previewing) {
      _saved = _Saved(
        ids: [for (final s in player.sequence) (s.tag as MediaItem).id],
        index: player.currentIndex ?? 0,
        position: player.position,
        wasPlaying: player.playing,
        loop: player.loopMode,
      );
    }
    previewing = true;
    previewKey = key;
    notifyListeners();
    try {
      await player.setLoopMode(LoopMode.off);
      await player.setAudioSource(AudioSource.uri(
        uri,
        tag: MediaItem(
          id: 'preview:$key',
          title: title,
          artist: (artist == null || artist.isEmpty) ? null : artist,
          artUri: (artUrl == null || artUrl.isEmpty) ? null : Uri.tryParse(artUrl),
        ),
      ));
      player.play();
    } catch (e) {
      debugPrint('preview failed: $e');
      await stopPreview();
      rethrow;
    }
  }

  /// Ends the preview and puts the user's queue back where it was.
  Future<void> stopPreview() async {
    if (!previewing) return;
    previewing = false;
    previewKey = null;
    final saved = _saved;
    _saved = null;
    notifyListeners();
    try {
      await player.stop();
      if (saved == null) return;
      await player.setLoopMode(saved.loop);
      final list = _playable([for (final id in saved.ids) if (store.tracks[id] != null) store.tracks[id]!]);
      if (list.isEmpty) {
        await player.clearAudioSources();
      } else {
        final wanted = saved.index < saved.ids.length ? saved.ids[saved.index] : null;
        var idx = list.indexWhere((t) => t.id == wanted);
        final pos = idx >= 0 ? saved.position : Duration.zero;
        if (idx < 0) idx = 0;
        _lastCountedId = list[idx].id; // getting the queue back is not a new play
        await player.setAudioSources([for (final t in list) _source(t)], initialIndex: idx, initialPosition: pos);
        if (saved.wasPlaying) player.play();
      }
    } catch (e) {
      debugPrint('restore after preview failed: $e');
    }
    notifyListeners();
  }

  /// The user started real playback while previewing: forget the old queue.
  Future<void> _dropPreview() async {
    if (!previewing) return;
    final loop = _saved?.loop;
    previewing = false;
    previewKey = null;
    _saved = null;
    if (loop != null) await player.setLoopMode(loop);
    notifyListeners();
  }

  // ------------------------------------------------------------ internals
  void _onTrackChanged() {
    if (previewing) return;
    final t = current;
    if (t?.id != _lastCountedId) clearAbLoop(notify: false);
    if (sleepMode == SleepMode.endOfTrack && _lastCountedId != null && t?.id != _lastCountedId) {
      player.pause();
      sleepMode = SleepMode.off;
      _endWatch?.cancel();
      _stopFade();
    }
    if (t != null && t.id != _lastCountedId) {
      _lastCountedId = t.id;
      store.markPlayed(t.id);
    }
    _persist();
    notifyListeners();
  }

  void _persist() {
    if (previewing) return;
    final seq = player.sequence;
    store.resumeQueue = [for (final s in seq) (s.tag as MediaItem).id];
    store.resumeIndex = player.currentIndex ?? 0;
    store.resumePositionMs = player.position.inMilliseconds;
    store.resumeShuffle = player.shuffleModeEnabled;
    store.resumeLoop = player.loopMode.index;
    store.save();
  }

  Future<void> _restore() async {
    final list = _playable([for (final id in store.resumeQueue) if (store.tracks[id] != null) store.tracks[id]!]);
    if (list.isEmpty) return;
    final wanted = store.resumeIndex < store.resumeQueue.length ? store.resumeQueue[store.resumeIndex] : null;
    var index = list.indexWhere((t) => t.id == wanted);
    if (index < 0) index = 0;
    try {
      await player.setLoopMode(LoopMode.values[store.resumeLoop.clamp(0, 2)]);
      await player.setShuffleModeEnabled(store.resumeShuffle);
      await player.setAudioSources(
        [for (final t in list) _source(t)],
        initialIndex: index,
        initialPosition: Duration(milliseconds: store.resumePositionMs),
      );
      _lastCountedId = list[index].id; // don't count a restore as a play
    } catch (e) {
      debugPrint('restore failed: $e');
    }
  }

  /// Rebuilds the queue after a sync removed or replaced files.
  Future<void> refreshAfterSync() async {
    if (!hasQueue || previewing) return;
    final ids = [for (final s in player.sequence) (s.tag as MediaItem).id];
    final missing = ids.where((id) => store.tracks[id] == null || !store.localFile(store.tracks[id]!).existsSync());
    if (missing.isEmpty) return;
    final wasPlaying = player.playing;
    final cur = current;
    final list = _playable([for (final id in ids) if (store.tracks[id] != null) store.tracks[id]!]);
    if (list.isEmpty) {
      await player.stop();
      await player.clearAudioSources();
      notifyListeners();
      return;
    }
    var idx = cur == null ? 0 : list.indexWhere((t) => t.id == cur.id);
    final pos = idx >= 0 ? player.position : Duration.zero;
    if (idx < 0) idx = 0;
    await player.setAudioSources([for (final t in list) _source(t)], initialIndex: idx, initialPosition: pos);
    if (wasPlaying) player.play();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _sleepTimer?.cancel();
    _fadeTimer?.cancel();
    _listenTimer?.cancel();
    _endWatch?.cancel();
    player.dispose();
    super.dispose();
  }
}

class _Saved {
  final List<String> ids;
  final int index;
  final Duration position;
  final bool wasPlaying;
  final LoopMode loop;
  _Saved({required this.ids, required this.index, required this.position, required this.wasPlaying, required this.loop});
}
