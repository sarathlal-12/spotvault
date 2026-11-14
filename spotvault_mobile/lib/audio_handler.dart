import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'library_store.dart';
import 'player_service.dart';

/// Connects the player to the phone's media controls: lock screen,
/// notification, Bluetooth and car screens (Android Auto shows your playlists
/// and songs; CarPlay and car Bluetooth show the song and controls).
class SpotVaultAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  SpotVaultAudioHandler(this.ps, this.store) {
    final p = ps.player;
    p.playbackEventStream.listen((_) => _broadcast());
    p.playingStream.listen((_) => _broadcast());
    p.shuffleModeEnabledStream.listen((_) => _broadcast());
    p.loopModeStream.listen((_) => _broadcast());
    p.sequenceStateStream.listen((_) => _syncQueue());
    p.currentIndexStream.listen((_) => _syncQueue());
    p.durationStream.listen((_) => _syncQueue());
  }

  final PlayerService ps;
  final LibraryStore store;

  AudioPlayer get _p => ps.player;

  void _broadcast() {
    final p = _p;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (p.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (p.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: p.playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
      queueIndex: p.currentIndex,
      shuffleMode: p.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: switch (p.loopMode) {
        LoopMode.off => AudioServiceRepeatMode.none,
        LoopMode.one => AudioServiceRepeatMode.one,
        LoopMode.all => AudioServiceRepeatMode.all,
      },
    ));
  }

  void _syncQueue() {
    final items = [for (final s in _p.sequence) s.tag as MediaItem];
    queue.add(items);
    final i = _p.currentIndex;
    if (i != null && i >= 0 && i < items.length) {
      final d = _p.duration;
      mediaItem.add(d == null ? items[i] : items[i].copyWith(duration: d));
    }
    _broadcast();
  }

  // ---------------------------------------------------------------- controls
  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> stop() => _p.stop();
  @override
  Future<void> seek(Duration position) => _p.seek(position);
  @override
  Future<void> skipToNext() => ps.next();
  @override
  Future<void> skipToPrevious() => ps.previous();
  @override
  Future<void> skipToQueueItem(int index) => ps.jumpTo(index);
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if ((shuffleMode != AudioServiceShuffleMode.none) != _p.shuffleModeEnabled) await ps.toggleShuffle();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => _p.setLoopMode(switch (repeatMode) {
        AudioServiceRepeatMode.none => LoopMode.off,
        AudioServiceRepeatMode.one => LoopMode.one,
        _ => LoopMode.all,
      });

  // ---------------------------------------------------------------- Android Auto library
  static const _liked = 'liked';

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    if (parentMediaId == AudioService.browsableRootId) {
      return [
        if (store.favorites.isNotEmpty) const MediaItem(id: 'list:$_liked', title: 'Liked songs', playable: false),
        for (final p in store.sortedPlaylists)
          MediaItem(
            id: 'list:${p.folder}',
            title: p.name,
            playable: false,
            artUri: store.coverFor(p)?.uri,
          ),
      ];
    }
    if (parentMediaId == AudioService.recentRootId) {
      return [for (final t in store.recentTracks.take(20)) _item(t, '')];
    }
    if (parentMediaId.startsWith('list:')) {
      final folder = parentMediaId.substring(5);
      return [for (final t in _tracks(folder)) _item(t, folder)];
    }
    return const [];
  }

  List<Track> _tracks(String folder) {
    if (folder == _liked) return store.likedTracks;
    final p = store.playlistByFolder(folder);
    return p == null ? const [] : store.tracksOf(p);
  }

  MediaItem _item(Track t, String folder) => MediaItem(
        id: 'song:$folder|${t.id}',
        title: t.title,
        artist: t.artist.isEmpty ? null : t.artist,
        album: t.album.isEmpty ? null : t.album,
        duration: t.length,
        artUri: store.artFor(t)?.uri,
        playable: true,
      );

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    if (!mediaId.startsWith('song:')) return;
    final rest = mediaId.substring(5);
    final bar = rest.indexOf('|');
    final folder = rest.substring(0, bar);
    final id = rest.substring(bar + 1);
    final list = folder.isEmpty ? [if (store.tracks[id] != null) store.tracks[id]!] : _tracks(folder);
    final start = list.indexWhere((t) => t.id == id);
    if (list.isNotEmpty) await ps.playTracks(list, start: start < 0 ? 0 : start);
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    return [
      for (final t in store.allTracks)
        if ('${t.title} ${t.artist}'.toLowerCase().contains(q)) _item(t, ''),
    ].take(40).toList();
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final found = await search(query);
    if (found.isNotEmpty) await playFromMediaId(found.first.id);
  }
}
