import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../player_service.dart';
import 'common.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([playerService, store]),
      builder: (context, _) {
        final t = playerService.current;
        final p = playerService.player;
        if (t == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Nothing playing', style: TextStyle(color: kMuted))),
          );
        }
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2E2560), kBg],
                stops: [0, 0.75],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              const Text('PLAYING FROM', style: TextStyle(fontSize: 10, letterSpacing: 1.2, color: kMuted)),
                              Text(_playlistName(t), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showTrackMenu(context, t)),
                      ],
                    ),
                    const Spacer(),
                    GestureDetector(
                      onHorizontalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        if (v < -300) playerService.next();
                        if (v > 300) playerService.previous();
                      },
                      child: LayoutBuilder(
                        builder: (_, c) {
                          final maxH = MediaQuery.sizeOf(context).height * 0.42;
                          final side = c.maxWidth < maxH ? c.maxWidth : maxH;
                          return Hero(tag: 'art', child: TrackArt(t, size: side, radius: 8));
                        },
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: kMuted)),
                            ],
                          ),
                        ),
                        IconButton(
                          iconSize: 28,
                          icon: Icon(store.isLiked(t.id) ? Icons.favorite : Icons.favorite_border,
                              color: store.isLiked(t.id) ? kAccent : Colors.white),
                          onPressed: () => store.toggleLike(t.id),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const _SeekBar(),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          iconSize: 26,
                          icon: Icon(Icons.shuffle, color: p.shuffleModeEnabled ? kAccent : Colors.white),
                          onPressed: playerService.toggleShuffle,
                        ),
                        IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: playerService.previous),
                        StreamBuilder<PlayerState>(
                          stream: p.playerStateStream,
                          builder: (_, snap) {
                            final playing = snap.data?.playing ?? p.playing;
                            final buffering = snap.data?.processingState == ProcessingState.loading;
                            return SizedBox(
                              width: 72,
                              height: 72,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  shape: const CircleBorder(),
                                  backgroundColor: kAccent,
                                  foregroundColor: Colors.white,
                                  padding: EdgeInsets.zero,
                                ),
                                onPressed: playerService.togglePlay,
                                child: buffering
                                    ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                                    : Icon(playing ? Icons.pause : Icons.play_arrow, size: 40),
                              ),
                            );
                          },
                        ),
                        IconButton(iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: playerService.next),
                        IconButton(
                          iconSize: 26,
                          icon: Icon(
                            p.loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                            color: p.loopMode == LoopMode.off ? Colors.white : kAccent,
                          ),
                          onPressed: playerService.cycleLoop,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () => _sleepSheet(context),
                          icon: Icon(Icons.bedtime_outlined,
                              color: playerService.sleepMode == SleepMode.off ? Colors.white : kAccent, size: 20),
                          label: Text(_sleepLabel(), style: TextStyle(color: playerService.sleepMode == SleepMode.off ? Colors.white : kAccent)),
                        ),
                        TextButton(
                          onPressed: () => _speedSheet(context),
                          child: Text('${p.speed.toStringAsFixed(p.speed % 1 == 0 ? 0 : 2)}×',
                              style: TextStyle(color: p.speed == 1 ? Colors.white : kAccent)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.queue_music),
                          onPressed: () => _queueSheet(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _playlistName(Track t) {
    for (final p in store.playlists) {
      if (p.folder == t.folder) return p.title;
    }
    return t.folder;
  }

  String _sleepLabel() {
    switch (playerService.sleepMode) {
      case SleepMode.off:
        return 'Sleep';
      case SleepMode.endOfTrack:
        return 'End of song';
      case SleepMode.timer:
        final left = playerService.sleepAt!.difference(DateTime.now());
        return '${left.inMinutes + 1} min';
    }
  }

  void _sleepSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Sleep timer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            for (final m in [5, 15, 30, 45, 60])
              ListTile(
                title: Text('$m minutes'),
                onTap: () {
                  playerService.setSleepTimer(Duration(minutes: m));
                  Navigator.pop(ctx);
                },
              ),
            ListTile(
              title: const Text('End of current song'),
              onTap: () {
                playerService.sleepAtEndOfTrack();
                Navigator.pop(ctx);
              },
            ),
            if (playerService.sleepMode != SleepMode.off)
              ListTile(
                title: const Text('Turn off timer', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  playerService.setSleepTimer(null);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _speedSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Playback speed', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            for (final s in [0.75, 1.0, 1.25, 1.5])
              ListTile(
                title: Text('$s×'),
                trailing: playerService.player.speed == s ? const Icon(Icons.check, color: kAccent) : null,
                onTap: () {
                  playerService.setSpeed(s);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _queueSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (_, scroll) => _QueueList(scroll),
      ),
    );
  }
}

class _QueueList extends StatelessWidget {
  final ScrollController scroll;
  const _QueueList(this.scroll);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final p = playerService.player;
        final seq = p.sequence;
        final cur = p.currentIndex ?? 0;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Expanded(child: Text('Queue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  Text('${seq.length} songs', style: const TextStyle(color: kMuted)),
                ],
              ),
            ),
            if (p.shuffleModeEnabled)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Shuffle is on: songs play in random order', style: TextStyle(color: kMuted, fontSize: 12)),
              ),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: scroll,
                buildDefaultDragHandles: false,
                itemCount: seq.length,
                onReorderItem: (from, to) => playerService.move(from, to),
                itemBuilder: (_, i) {
                  final item = seq[i].tag as MediaItem;
                  final t = store.tracks[item.id];
                  final isCur = i == cur;
                  return Dismissible(
                    key: ValueKey('${item.id}-$i'),
                    direction: isCur ? DismissDirection.none : DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red.shade900,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete),
                    ),
                    onDismissed: (_) => playerService.removeAt(i),
                    child: ListTile(
                      leading: t == null ? const Icon(Icons.music_note) : TrackArt(t, size: 40),
                      title: Text(item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: isCur ? kAccent : Colors.white)),
                      subtitle: Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted)),
                      trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle, color: kMuted)),
                      onTap: () => playerService.jumpTo(i),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar();

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? dragging;

  @override
  Widget build(BuildContext context) {
    final p = playerService.player;
    return StreamBuilder<Duration>(
      stream: p.positionStream,
      builder: (context, snap) {
        final total = p.duration ?? Duration.zero;
        final pos = snap.data ?? Duration.zero;
        final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);
        final value = (dragging ?? pos.inMilliseconds.toDouble()).clamp(0.0, max);
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: kAccent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                min: 0,
                max: max,
                value: value,
                onChanged: (v) => setState(() => dragging = v),
                onChangeEnd: (v) {
                  p.seek(Duration(milliseconds: v.round()));
                  setState(() => dragging = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(Duration(milliseconds: value.round())), style: const TextStyle(color: kMuted, fontSize: 12)),
                  Text(formatDuration(total), style: const TextStyle(color: kMuted, fontSize: 12)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
