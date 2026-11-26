import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;

import 'library_store.dart';

enum SleepMode { off, timer, endOfTrack }

/// Shuffle order where songs you queue ("Play next", "Add to queue") go right
/// after the song playing now (and after songs you queued before), instead of
/// a random spot.
class QueueShuffleOrder extends DefaultShuffleOrder {
  /// Sequence index the next inserted song should follow; set before each insert.
  int? insertAfter;

  @override
  void insert(int index, int count) {
    final after = insertAfter;
    final pos = after == null ? -1 : indices.indexOf(after);
    if (pos < 0) return super.insert(index, count);
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) indices[i] += count;
    }
    indices.insertAll(pos + 1, [for (var i = 0; i < count; i++) index + i]);
    insertAfter = null;
  }
}

/// Music player: queue, shuffle, repeat, sleep timer, resume where you left off.
/// Lock-screen, notification and car controls come from audio_handler.dart.
class PlayerService extends ChangeNotifier {
  final LibraryStore store;

  /// Android's equalizer (iPhone has none in the audio player).
  final AndroidEqualizer? equalizer = Platform.isAndroid ? AndroidEqualizer() : null;
  late final AudioPlayer player = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [if (equalizer != null) equalizer!]),
  );

  /// Songs that aren't in the library (Jam songs from other phones): id -> track / file / art.
  final Map<String, Track> extraTracks = {};
  final Map<String, String> extraFiles = {};
  final Map<String, String> extraArt = {};

  Track? trackById(String id) => store.tracks[id] ?? extraTracks[id];

  String _pathOf(Track t) => extraFiles[t.id] ?? store.localFile(t).path;

  // Volume is the product of: Smart Sleep fade, song transition fade, even volume.
  double _sleepFactor = 1, _fadeFactor = 1, _gainFactor = 1;
  double _lastVolume = -1;

  void _applyVolume() {
    final v = (_sleepFactor * _fadeFactor * _gainFactor).clamp(0.0, 1.0);
    if ((v - _lastVolume).abs() < 0.01) return;
    _lastVolume = v;
    player.setVolume(v);
  }

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

  /// Internet Jam: keep the "preview" (the Jam song) when it ends instead of
  /// putting your own queue back; the Jam loads the next song.
  bool holdPreview = false;
  String? previewKey;
  _Saved? _saved;

  Future<void> init() async {
    if (!Platform.isWindows) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      // Pause when headphones are unplugged / Bluetooth disconnects.
      session.becomingNoisyEventStream.listen((_) => player.pause());
    }

    player.currentIndexStream.listen((_) => _onTrackChanged());
    player.sequenceStateStream.listen((_) => notifyListeners());
    player.playerStateStream.listen((s) {
      notifyListeners();
      if (previewing && !holdPreview && !onlineList && s.processingState == ProcessingState.completed) {
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
      _transitionFade(pos);
    });
    await applyEqualizer();

    await _restore();
  }

  // ------------------------------------------------------------ state
  List<Track> get queue => [
        for (final s in player.sequence)
          if (trackById((s.tag as MediaItem).id) != null) trackById((s.tag as MediaItem).id)!
      ];

  /// Tests and screen renders: pretend this song is playing.
  @visibleForTesting
  Track? debugCurrent;

  Track? get current {
    if (debugCurrent != null) return debugCurrent;
    final i = player.currentIndex;
    final seq = player.sequence;
    if (i == null || i < 0 || i >= seq.length) return null;
    return trackById((seq[i].tag as MediaItem).id);
  }

  // Windows: the mpv backend shuffles its own playlist and ignores ours, so
  // there the list itself is put in shuffled order and mpv never shuffles.
  static final bool _listShuffle = Platform.isWindows;
  bool _shuffleOn = false;
  List<String> _unshuffled = const [];

  /// Whether shuffle is on (use this, not player.shuffleModeEnabled).
  bool get shuffleOn => _listShuffle ? _shuffleOn : player.shuffleModeEnabled;

  /// Queue in the order it will actually play (respects shuffle).
  List<int> get playOrder =>
      (!_listShuffle && player.shuffleModeEnabled) ? player.shuffleIndices : List.generate(player.sequence.length, (i) => i);

  bool get hasQueue => player.sequence.isNotEmpty;

  // ------------------------------------------------------------ building sources
  AudioSource _source(Track t) {
    final extra = extraArt[t.id];
    final art = extra != null ? File(extra) : store.artFor(t);
    return AudioSource.file(
      _pathOf(t),
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

  List<Track> _playable(List<Track> tracks) => tracks.where((t) => File(_pathOf(t)).existsSync()).toList();

  /// Builds a playable source for [t] (used by Jam to add songs as they arrive).
  AudioSource sourceFor(Track t) => _source(t);

  // ------------------------------------------------------------ actions
  Future<void> playTracks(List<Track> tracks, {int start = 0, bool? shuffle}) async {
    await _dropPreview();
    final startTrack = (start >= 0 && start < tracks.length) ? tracks[start] : null;
    var list = _playable(tracks);
    if (list.isEmpty) return;
    var index = startTrack == null ? 0 : list.indexWhere((t) => t.id == startTrack.id);
    if (index < 0) index = 0;

    if (_listShuffle) {
      _shuffleOn = shuffle ?? _shuffleOn;
      _unshuffled = [for (final t in list) t.id];
      if (_shuffleOn) {
        final first = startTrack == null ? null : list[index];
        final rest = list.where((t) => t.id != first?.id).toList()..shuffle();
        list = [if (first != null) first, ...rest];
        index = 0;
      }
      await player.setAudioSources([for (final t in list) _source(t)], initialIndex: index, shuffleOrder: _newOrder());
      player.play();
      _persist();
      notifyListeners();
      return;
    }

    if (shuffle != null) await player.setShuffleModeEnabled(shuffle);
    await player.setAudioSources([for (final t in list) _source(t)], initialIndex: index, shuffleOrder: _newOrder());
    if (shuffle == true) {
      await player.shuffle();
      // When shuffling a whole list, start from the first shuffled song.
      if (startTrack == null) await player.seek(Duration.zero, index: player.shuffleIndices.first);
    }
    player.play();
    _persist();
  }

  // ------------------------------------------------------------ your queue
  QueueShuffleOrder _order = QueueShuffleOrder();
  QueueShuffleOrder _newOrder() => _order = QueueShuffleOrder();

  /// Songs you queued that haven't played yet (ids), in play order.
  final List<String> _queued = [];

  /// The sequence index of the last song in the "queued by you" run right
  /// after the current song (or the current song when there is none).
  int _queueAnchor() {
    final cur = player.currentIndex ?? 0;
    final order = playOrder;
    final seq = player.sequence;
    final pos = order.indexOf(cur);
    var anchor = cur;
    if (pos < 0) return anchor;
    for (final i in order.skip(pos + 1)) {
      if (i < seq.length && _queued.contains((seq[i].tag as MediaItem).id)) {
        anchor = i;
      } else {
        break;
      }
    }
    return anchor;
  }

  Future<void> _insertAfter(int anchor, Track t) async {
    _order.insertAfter = anchor;
    await player.insertAudioSource(anchor + 1, _source(t));
  }

  /// Plays [t] right after the current song.
  Future<void> playNext(Track t) async {
    if (previewing) await stopPreview();
    if (!hasQueue) return playTracks([t]);
    await _insertAfter(player.currentIndex ?? 0, t);
    _queued.insert(0, t.id);
    _persist();
    notifyListeners();
  }

  /// Plays [t] after the current song and the songs you queued before it.
  Future<void> addToQueue(Track t) async {
    if (previewing) await stopPreview();
    if (!hasQueue) return playTracks([t]);
    await _insertAfter(_queueAnchor(), t);
    _queued.add(t.id);
    _persist();
    notifyListeners();
  }

  Future<void> removeAt(int index) async {
    await player.removeAudioSourceAt(index);
    _persist();
  }

  Future<void> move(int from, int to) async {
    await player.moveAudioSource(from, to);
    _persist();
  }

  /// Drag-to-reorder in the queue. [from] and [to] are positions in the order
  /// songs will play (what the queue shows). With shuffle on (phones), the
  /// shuffled order is kept as the real order so the drag sticks; shuffle then
  /// shows as off because songs play exactly as listed.
  Future<void> moveInQueue(int from, int to) async {
    if (from == to) return;
    final order = playOrder;
    if (from < 0 || to < 0 || from >= order.length || to >= order.length) return;
    final shuffledHere = !_listShuffle && player.shuffleModeEnabled;
    if (!shuffledHere && !_listShuffle) return move(order[from], order[to]);
    // Windows (its mpv list is the play order) and shuffled phones: rebuild.
    final seq = player.sequence;
    final list = [for (final i in order) if (i < seq.length) trackById((seq[i].tag as MediaItem).id)].whereType<Track>().toList();
    if (list.length != order.length) return;
    final cur = current;
    list.insert(to, list.removeAt(from));
    final pos = player.position;
    final playing = player.playing;
    if (shuffledHere) await player.setShuffleModeEnabled(false);
    await player.setAudioSources([for (final t in list) _source(t)],
        initialIndex: cur == null ? 0 : list.indexWhere((t) => t.id == cur.id).clamp(0, list.length - 1), initialPosition: pos, shuffleOrder: _newOrder());
    if (playing) player.play();
    _persist();
    notifyListeners();
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

  /// Jump forward or back inside the song (the 10-second buttons and double-tap).
  Future<void> seekBy(Duration d) async {
    var to = player.position + d;
    final len = player.duration;
    if (to < Duration.zero) to = Duration.zero;
    if (len != null && to > len - const Duration(seconds: 1)) to = len - const Duration(seconds: 1);
    await player.seek(to < Duration.zero ? Duration.zero : to);
  }

  /// Jump to a fraction (0..1) of the song (the Focus player's draggable ring).
  Future<void> seekToFraction(double f) async {
    final len = player.duration;
    if (len == null || len == Duration.zero) return;
    await player.seek(len * f.clamp(0.0, 0.995));
  }

  Future<void> toggleShuffle() async {
    if (onlineList) return; // an online playlist plays in its own order
    if (_listShuffle) return _reorder(!_shuffleOn);
    final on = !player.shuffleModeEnabled;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
    _persist();
    notifyListeners();
  }

  /// Windows shuffle: rebuilds the list in shuffled (or original) order and
  /// keeps the current song playing where it is.
  Future<void> _reorder(bool on) async {
    final seq = queue;
    final cur = current;
    _shuffleOn = on;
    if (cur == null || seq.length < 2) {
      if (on) _unshuffled = [for (final t in seq) t.id];
      _persist();
      notifyListeners();
      return;
    }
    List<Track> next;
    if (on) {
      _unshuffled = [for (final t in seq) t.id];
      next = [cur, ...seq.where((t) => t.id != cur.id).toList()..shuffle()];
    } else {
      final inSeq = {for (final t in seq) t.id};
      final known = _unshuffled.toSet();
      final orig = [
        for (final id in _unshuffled)
          if (inSeq.contains(id) && trackById(id) != null) trackById(id)!
      ];
      // Songs added since shuffle went on (your queue) stay right after this one.
      final extra = seq.where((t) => !known.contains(t.id) && t.id != cur.id).toList();
      final i = orig.indexWhere((t) => t.id == cur.id);
      next = i < 0
          ? [cur, ...extra, ...orig]
          : [...orig.take(i + 1), ...extra, ...orig.skip(i + 1)];
    }
    final pos = player.position;
    final playing = player.playing;
    await player.setAudioSources([for (final t in next) _source(t)],
        initialIndex: next.indexWhere((t) => t.id == cur.id), initialPosition: pos, shuffleOrder: _newOrder());
    if (playing) player.play();
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
      _sleepFactor = (1 - i / steps).clamp(0.0, 1.0);
      _applyVolume();
      if (i >= steps) {
        t.cancel();
        done();
      }
    });
  }

  void _stopFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _sleepFactor = 1;
    _applyVolume();
  }

  // ------------------------------------------------------------ sound
  /// Smooth transitions: fade the end of a song out and the next one in.
  void _transitionFade(Duration pos) {
    final fade = store.crossfadeSec;
    var f = 1.0;
    if (fade > 0 && !previewing && !abActive) {
      final ms = fade * 1000;
      final total = player.duration;
      final hasNext = player.hasNext || player.loopMode != LoopMode.off;
      if (total != null && hasNext) {
        final left = (total - pos).inMilliseconds;
        if (left < ms) f = math.max(0.0, left / ms);
      }
      if (pos.inMilliseconds < ms) f = math.min(f, math.max(0.15, pos.inMilliseconds / ms));
    }
    if ((f - _fadeFactor).abs() > 0.01 || (f == 1 && _fadeFactor != 1)) {
      _fadeFactor = f;
      _applyVolume();
    }
  }

  void _applyGain() {
    final g = store.evenVolume && !previewing ? (current?.gain ?? 0) : 0.0;
    _gainFactor = math.pow(10, g / 20).toDouble();
    _applyVolume();
  }

  /// Equalizer presets: dB by band centre frequency.
  static const eqPresets = ['off', 'bass', 'vocal', 'treble', 'acoustic', 'custom'];

  static double presetGain(String preset, double hz) => switch (preset) {
        'bass' => hz < 120
            ? 6
            : hz < 300
                ? 3.5
                : hz < 1000
                    ? 0
                    : -1,
        'vocal' => hz < 200
            ? -2
            : hz < 800
                ? 0.5
                : hz < 5000
                    ? 3.5
                    : 1,
        'treble' => hz < 1000
            ? 0
            : hz < 4000
                ? 2.5
                : 5,
        'acoustic' => hz < 120
            ? 3
            : hz < 600
                ? 1
                : hz < 3000
                    ? 1.5
                    : 2.5,
        _ => 0,
      };

  /// Applies the saved equalizer setting (Android only).
  Future<void> applyEqualizer() async {
    final eq = equalizer;
    if (eq == null) return;
    try {
      final preset = store.eqPreset;
      await eq.setEnabled(preset != 'off');
      if (preset == 'off') return;
      final params = await eq.parameters;
      for (var i = 0; i < params.bands.length; i++) {
        final b = params.bands[i];
        final db = preset == 'custom' ? (i < store.eqCustom.length ? store.eqCustom[i] : 0.0) : presetGain(preset, b.centerFrequency);
        await b.setGain(db.clamp(params.minDecibels, params.maxDecibels));
      }
    } catch (e) {
      debugPrint('equalizer: $e');
    }
  }

  Future<void> setSound({int? crossfadeSec, bool? evenVolume, String? eqPreset}) async {
    if (crossfadeSec != null) store.crossfadeSec = crossfadeSec;
    if (evenVolume != null) store.evenVolume = evenVolume;
    if (eqPreset != null) store.eqPreset = eqPreset;
    store.changed();
    _applyGain();
    _transitionFade(player.position);
    if (eqPreset != null) await applyEqualizer();
    notifyListeners();
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
    _fadeFactor = 1;
    _gainFactor = 1;
    _applyVolume();
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

  /// Windows "Play online": a whole playlist streamed song after song.
  bool onlineList = false;

  /// Cover art (a web link) of the online songs playing now, by track id.
  final Map<String, String> onlineArt = {};

  /// Online songs that can be saved from the player (Trending): track id -> song,
  /// and how to save one. Null when the online list can't be saved.
  final Map<String, Map<String, dynamic>> onlineSongs = {};
  Future<void> Function(BuildContext context, Map<String, dynamic> song)? onlineSave;

  Map<String, dynamic>? get currentOnlineSong => onlineList ? onlineSongs[current?.id] : null;

  /// Plays [songs] from the internet in order, starting at [start]. Each song is a
  /// stream URL plus a [Track] for its title and artist. The user's own queue comes
  /// back with [stopPreview], or is dropped when they play a downloaded song.
  Future<void> playOnline(List<(Uri, Track)> songs,
      {int start = 0,
      required String key,
      List<String>? arts,
      List<Map<String, dynamic>>? saveable,
      Future<void> Function(BuildContext context, Map<String, dynamic> song)? onSave}) async {
    if (songs.isEmpty) return;
    onlineArt.clear();
    onlineSongs.clear();
    onlineSave = onSave;
    for (final (i, (_, t)) in songs.indexed) {
      if (arts != null && i < arts.length && arts[i].isNotEmpty) onlineArt[t.id] = arts[i];
      if (saveable != null && i < saveable.length) onlineSongs[t.id] = saveable[i];
    }
    _fadeFactor = 1;
    _gainFactor = 1;
    _applyVolume();
    if (!previewing) {
      _saved = _Saved(
        ids: [for (final s in player.sequence) (s.tag as MediaItem).id],
        index: player.currentIndex ?? 0,
        position: player.position,
        wasPlaying: player.playing,
        loop: player.loopMode,
      );
    }
    extraTracks.removeWhere((k, _) => k.startsWith('online:'));
    for (final (_, t) in songs) {
      extraTracks[t.id] = t;
    }
    previewing = true;
    onlineList = true;
    previewKey = key;
    notifyListeners();
    try {
      await player.setLoopMode(LoopMode.off);
      await player.setAudioSources(
        [
          for (final (u, t) in songs)
            AudioSource.uri(u,
                tag: MediaItem(
                    id: t.id,
                    title: t.title,
                    artist: t.artist.isEmpty ? null : t.artist,
                    artUri: onlineArt[t.id] == null ? null : Uri.tryParse(onlineArt[t.id]!))),
        ],
        initialIndex: start.clamp(0, songs.length - 1),
      );
      player.play();
    } catch (e) {
      debugPrint('play online failed: $e');
      await stopPreview();
      rethrow;
    }
  }

  /// Ends the preview and puts the user's queue back where it was.
  Future<void> stopPreview() async {
    if (!previewing) return;
    previewing = false;
    onlineList = false;
    previewKey = null;
    final saved = _saved;
    _saved = null;
    notifyListeners();
    try {
      await player.stop();
      if (saved == null) return;
      await player.setLoopMode(saved.loop);
      final list = _playable([
        for (final id in saved.ids)
          if (store.tracks[id] != null) store.tracks[id]!
      ]);
      if (list.isEmpty) {
        await player.clearAudioSources();
      } else {
        final wanted = saved.index < saved.ids.length ? saved.ids[saved.index] : null;
        var idx = list.indexWhere((t) => t.id == wanted);
        final pos = idx >= 0 ? saved.position : Duration.zero;
        if (idx < 0) idx = 0;
        _lastCountedId = list[idx].id; // getting the queue back is not a new play
        await player.setAudioSources([for (final t in list) _source(t)], initialIndex: idx, initialPosition: pos, shuffleOrder: _newOrder());
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
    onlineList = false;
    previewKey = null;
    _saved = null;
    if (loop != null) await player.setLoopMode(loop);
    notifyListeners();
  }

  // ------------------------------------------------------------ internals
  void _onTrackChanged() {
    if (previewing) return;
    final playingId = current?.id;
    if (playingId != null) _queued.remove(playingId);
    _applyGain();
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
    store.resumeShuffle = shuffleOn;
    store.resumeLoop = player.loopMode.index;
    store.save();
  }

  Future<void> _restore() async {
    final list = _playable([
      for (final id in store.resumeQueue)
        if (store.tracks[id] != null) store.tracks[id]!
    ]);
    if (list.isEmpty) return;
    final wanted = store.resumeIndex < store.resumeQueue.length ? store.resumeQueue[store.resumeIndex] : null;
    var index = list.indexWhere((t) => t.id == wanted);
    if (index < 0) index = 0;
    try {
      await player.setLoopMode(LoopMode.values[store.resumeLoop.clamp(0, 2)]);
      if (_listShuffle) {
        // The saved list is already in play order.
        _shuffleOn = store.resumeShuffle;
        _unshuffled = [for (final t in list) t.id];
      } else {
        await player.setShuffleModeEnabled(store.resumeShuffle);
      }
      await player.setAudioSources(
        [for (final t in list) _source(t)],
        initialIndex: index,
        initialPosition: Duration(milliseconds: store.resumePositionMs),
        shuffleOrder: _newOrder(),
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
    final list = _playable([
      for (final id in ids)
        if (store.tracks[id] != null) store.tracks[id]!
    ]);
    if (list.isEmpty) {
      await player.stop();
      await player.clearAudioSources();
      notifyListeners();
      return;
    }
    var idx = cur == null ? 0 : list.indexWhere((t) => t.id == cur.id);
    final pos = idx >= 0 ? player.position : Duration.zero;
    if (idx < 0) idx = 0;
    await player.setAudioSources([for (final t in list) _source(t)], initialIndex: idx, initialPosition: pos, shuffleOrder: _newOrder());
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
