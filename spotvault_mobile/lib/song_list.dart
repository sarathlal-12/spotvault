/// Song list backup: every playlist and its songs as plain text, so a new phone
/// or the Windows app can download them all again.
///
/// ```
/// # SpotVault song list
/// ## Drive mix
/// Midnight Drive - Night Cassette
/// Neon Rain - Mira Vale
/// ```
library;

import 'library_store.dart';

const String songListHeader = '# SpotVault song list';

/// The song list for [lib]: each playlist under "## name", one "Title - Artist" per line.
/// Songs that aren't in any playlist go under "## Other songs".
String buildSongList(LibraryStore lib, {DateTime? now}) {
  final out = StringBuffer('$songListHeader\n');
  final d = now ?? DateTime.now();
  out.writeln('# Saved ${d.year}-${_two(d.month)}-${_two(d.day)}. Import it in the SpotVault Windows app: Settings, Song list.');
  final seen = <String>{};
  for (final pl in lib.sortedPlaylists) {
    final tracks = lib.tracksOf(pl);
    if (tracks.isEmpty) continue;
    out.writeln();
    out.writeln('## ${pl.name}');
    for (final t in tracks) {
      seen.add(t.id);
      out.writeln(songLine(t));
    }
  }
  final rest = [for (final t in lib.tracks.values) if (!seen.contains(t.id)) t];
  if (rest.isNotEmpty) {
    out.writeln();
    out.writeln('## Other songs');
    for (final t in rest) {
      out.writeln(songLine(t));
    }
  }
  return out.toString();
}

/// "Title - Artist", or just the title when the artist is unknown.
String songLine(Track t) {
  final title = t.title.replaceAll('\n', ' ').trim();
  final artist = t.artist.replaceAll('\n', ' ').trim();
  return artist.isEmpty || artist.toLowerCase() == 'unknown' ? title : '$title - $artist';
}

/// Reads a song list back: {playlist name: [song lines]}, in order.
/// Lines starting with a single "#" are notes; songs before any "## name" go to "Imported".
Map<String, List<String>> parseSongList(String text) {
  final lists = <String, List<String>>{};
  var current = 'Imported';
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('## ')) {
      final name = line.substring(3).trim();
      current = name.isEmpty ? 'Imported' : name;
      continue;
    }
    if (line.startsWith('#')) continue;
    final song = line.replaceFirst(RegExp(r'^(\d+[.)]\s+|[-*•]\s+)'), '');
    if (song.isNotEmpty) (lists[current] ??= []).add(song);
  }
  return lists;
}

String _two(int n) => n.toString().padLeft(2, '0');
