import 'package:flutter_test/flutter_test.dart';
import 'package:spotvault_mobile/song_list.dart';

void main() {
  test('reads playlists, notes and numbered lines', () {
    final lists = parseSongList('''
# SpotVault song list
# Saved 2026-11-18.

## Drive mix
Midnight Drive - Night Cassette
1. Neon Rain - Mira Vale

## Late night
- Ocean Eyes
''');
    expect(lists.keys, ['Drive mix', 'Late night']);
    expect(lists['Drive mix'], ['Midnight Drive - Night Cassette', 'Neon Rain - Mira Vale']);
    expect(lists['Late night'], ['Ocean Eyes']);
  });

  test('songs before any playlist go to Imported', () {
    expect(parseSongList('Kesariya - Arijit Singh\r\nPasoori'), {
      'Imported': ['Kesariya - Arijit Singh', 'Pasoori'],
    });
  });

  test('an empty list has no playlists', () {
    expect(parseSongList('# SpotVault song list\n\n'), isEmpty);
  });
}
