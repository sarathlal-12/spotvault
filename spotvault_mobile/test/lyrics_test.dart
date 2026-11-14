import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/lyrics_service.dart';

void main() {
  test('LRC lines are parsed, sorted and found by time', () {
    final lines = parseLrc('[ar: someone]\n[00:12.15] second\n[00:07.82] first\n[01:02.5][02:10.00] chorus\n[03:00] ');
    expect(lines.map((l) => l.text), ['first', 'second', 'chorus', 'chorus', '']);
    expect(lines[0].at, const Duration(seconds: 7, milliseconds: 820));
    expect(lines[2].at, const Duration(minutes: 1, seconds: 2, milliseconds: 500));
    final l = Lyrics(lines: lines);
    expect(l.indexAt(const Duration(seconds: 3)), -1);
    expect(l.indexAt(const Duration(seconds: 10)), 0);
    expect(l.indexAt(const Duration(minutes: 1, seconds: 30)), 2);
    expect(l.indexAt(const Duration(minutes: 5)), 4);
  });

  test('titles and artists are cleaned for the lookup', () {
    expect(LyricsService.cleanTitle('Believer (Official Audio)'), 'Believer');
    expect(LyricsService.cleanTitle('Mazhaye [From "Mazha"] - Remastered 2020'), 'Mazhaye');
    expect(LyricsService.cleanTitle('Sucker for Pain feat. Logic'), 'Sucker for Pain');
    expect(LyricsService.mainArtist('Imagine Dragons, Lil Wayne'), 'Imagine Dragons');
    expect(LyricsService.mainArtist('Govind Vasantha & Thaikkudam Bridge'), 'Govind Vasantha');
    expect(LyricsService.mainArtist('Anirudh - Topic'), 'Anirudh');
  });
}
