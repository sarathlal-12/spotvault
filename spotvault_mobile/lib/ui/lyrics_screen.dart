import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../library_store.dart';
import '../lyrics_service.dart';
import 'aurora.dart';
import 'common.dart';

/// Opens the full-screen lyrics for the song that's playing.
void openLyrics(BuildContext context) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, __, ___) => const LyricsScreen(),
    transitionsBuilder: (_, a, __, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// Lyrics with the current line lit up; follows the song, tap a line to jump.
class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  String? _trackId;
  Future<Lyrics>? _lyrics;
  int _shown = -2;
  bool _userScrolling = false;
  DateTime _lastUserScroll = DateTime(2000);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _load(Track t) {
    if (_trackId == t.id) return;
    _trackId = t.id;
    _keys.clear();
    _shown = -2;
    _lyrics = lyricsService.get(t);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _follow(int index) {
    if (index == _shown) return;
    _shown = index;
    // Leave the user alone for a few seconds after they scroll.
    if (_userScrolling || DateTime.now().difference(_lastUserScroll) < const Duration(seconds: 4)) return;
    final key = _keys[index < 0 ? 0 : index];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final t = playerService.current;
        if (t == null) return const Scaffold(body: SizedBox.shrink());
        _load(t);
        final colors = artColorsFor(t.title);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(colors.first, Colors.black, 0.35)!, Color.lerp(colors.last, Colors.black, 0.65)!],
              ),
            ),
            child: SafeArea(
              child: GestureDetector(
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 500) Navigator.pop(context);
                },
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                      child: Row(children: [
                        IconButton(
                          tooltip: 'Close lyrics',
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 32),
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 4),
                        TrackArt(t, size: 40),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                            Text(t.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
                          ]),
                        ),
                        IconButton(
                          tooltip: playerService.player.playing ? 'Pause' : 'Play',
                          icon: Icon(playerService.player.playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                              color: Colors.white, size: 40),
                          onPressed: () => playerService.player.playing ? playerService.player.pause() : playerService.player.play(),
                        ),
                      ]),
                    ),
                    Expanded(child: _body(t)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(Track t) {
    return FutureBuilder<Lyrics>(
      future: _lyrics,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        }
        if (snap.hasError) {
          return _message(isOffline(snap.error!)
              ? 'Lyrics need the internet the first time.\nOnce found, they work offline.'
              : "Couldn't get lyrics right now.", retry: true);
        }
        final l = snap.data!;
        if (l.isEmpty) return _message('No lyrics found for this song.');
        if (!l.synced) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 60),
            children: [
              Text('Not timed: these lyrics don\'t follow the song.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
              const SizedBox(height: 14),
              Text(l.plain, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, height: 1.5)),
            ],
          );
        }
        return StreamBuilder<Duration>(
          stream: playerService.player.positionStream,
          builder: (context, _) {
            final pos = playerService.player.position + const Duration(milliseconds: 150);
            final now = l.indexAt(pos);
            _follow(now);
            return NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification && n.dragDetails != null) _userScrolling = true;
                if (n is ScrollEndNotification && _userScrolling) {
                  _userScrolling = false;
                  _lastUserScroll = DateTime.now();
                }
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(28, 24, 28, MediaQuery.sizeOf(context).height * 0.45),
                itemCount: l.lines.length,
                itemBuilder: (_, i) {
                  final line = l.lines[i];
                  final key = _keys.putIfAbsent(i, GlobalKey.new);
                  final state = i == now ? 0 : (i < now ? -1 : 1);
                  return GestureDetector(
                    key: key,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _lastUserScroll = DateTime(2000);
                      playerService.player.seek(line.at);
                    },
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      style: TextStyle(
                        fontSize: state == 0 ? 27 : 23,
                        height: 1.3,
                        fontWeight: FontWeight.w800,
                        color: Colors.white.withValues(alpha: state == 0 ? 1 : (state < 0 ? 0.45 : 0.32)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Text(line.text.isEmpty ? '♪' : line.text),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _message(String text, {bool retry = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lyrics_outlined, color: Colors.white.withValues(alpha: 0.6), size: 44),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), height: 1.4)),
            if (retry) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => setState(() {
                  _trackId = null;
                }),
                child: const Text('Try again'),
              ),
            ],
          ]),
        ),
      );
}
