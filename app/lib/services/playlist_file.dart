import 'dart:convert';

/// One track line of an M3U playlist: the `#EXTINF` display title (empty when
/// the file has none) and the path or URL it points at.
typedef PlaylistFileEntry = ({String title, String target});

/// Reads and writes the plain `.m3u` / `.m3u8` playlists that Pear Music and
/// most other players (VLC, foobar2000, Poweramp, MusicBee...) understand.
class PlaylistFile {
  PlaylistFile._();

  /// Decodes raw file bytes. Playlists from older Windows players are often
  /// Latin-1 rather than UTF-8, and many editors prepend a byte order mark;
  /// neither should make an import fail or turn the header into a track.
  static String decode(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes, allowInvalid: true);
    }
    if (text.startsWith('﻿')) text = text.substring(1);
    return text;
  }

  /// Parses [content] into its playlist name (from `#PLAYLIST:`, null when
  /// absent) and its entries in file order.
  static ({String? name, List<PlaylistFileEntry> entries}) parse(
    String content,
  ) {
    if (content.startsWith('﻿')) content = content.substring(1);
    String? name;
    final entries = <PlaylistFileEntry>[];
    String? pendingTitle;
    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#PLAYLIST:')) {
          final value = line.substring('#PLAYLIST:'.length).trim();
          if (value.isNotEmpty) name = value;
        } else if (line.startsWith('#EXTINF:')) {
          pendingTitle = extinfTitle(line);
        }
        continue;
      }
      entries.add((title: pendingTitle ?? '', target: line));
      pendingTitle = null;
    }
    return (name: name, entries: entries);
  }

  /// The display text after the first comma of an `#EXTINF:` line.
  static String extinfTitle(String line) {
    final comma = line.indexOf(',');
    return comma == -1 ? '' : line.substring(comma + 1).trim();
  }

  /// Builds an extended M3U playlist. `#EXTINF` titles have line breaks
  /// removed so a stray newline in a song title cannot split an entry.
  static String build(String name, Iterable<PlaylistFileEntry> entries) {
    final buffer = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#PLAYLIST:${_oneLine(name)}');
    for (final entry in entries) {
      buffer
        ..writeln('#EXTINF:-1,${_oneLine(entry.title)}')
        ..writeln(entry.target);
    }
    return buffer.toString();
  }

  /// A file name safe on Windows and Android for [name] plus [extension].
  static String safeFileName(String name, {String extension = 'm3u8'}) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    return '${safe.isEmpty ? 'playlist' : safe}.$extension';
  }

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
}
