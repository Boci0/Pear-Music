import '../models/song.dart';
import 'recommendation_service.dart';

/// Helpers for the portable "library profile" format.
///
/// A profile is an M3U playlist file that lists only songs originally added
/// from links: they carry a YouTube ID, so they can be re-fetched on any
/// device. Songs added from disk stay on the device that created them, so
/// they are excluded on export and never accepted on import.
class LibraryProfile {
  LibraryProfile._();

  static const String marker = '#PEARMUSIC-LIBRARY-PROFILE';
  static final RegExp _videoIdTag = RegExp(r'\[([a-zA-Z0-9_-]{11})\]');

  /// Extracts the YouTube ID stored in a link-added song's file name.
  static String? videoIdOf(Song song) =>
      _videoIdTag.firstMatch(song.fileName)?.group(1);

  /// Builds the profile file content for [songs]. Local-only songs are
  /// skipped and duplicate YouTube IDs are collapsed (first occurrence wins,
  /// library order is kept). Returns null when there is nothing to export.
  static String? build(List<Song> songs) {
    final entries = <ProfileEntry>[];
    final seen = <String>{};
    for (final song in songs) {
      final videoId = videoIdOf(song);
      if (videoId == null || !seen.add(videoId)) continue;
      entries.add(ProfileEntry(videoId: videoId, title: song.title));
    }
    if (entries.isEmpty) return null;

    final buffer = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln(marker)
      ..writeln('#PLAYLIST:Pear Music Library');
    for (final entry in entries) {
      buffer.writeln('#EXTINF:-1,${entry.title}');
      buffer.writeln('https://www.youtube.com/watch?v=${entry.videoId}');
    }
    return buffer.toString();
  }

  /// Parses [content] into ordered, de-duplicated entries. Lines without a
  /// YouTube link (comments, local paths) are ignored so nothing foreign can
  /// leak into the library.
  static List<ProfileEntry> parse(String content) {
    final entries = <ProfileEntry>[];
    final seen = <String>{};
    var pendingTitle = '';
    for (final raw in content.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        pendingTitle = comma == -1 ? '' : line.substring(comma + 1).trim();
        continue;
      }
      if (line.startsWith('#')) continue;
      final videoId = RecommendationService.extractVideoId(line);
      if (videoId == null || !seen.add(videoId)) {
        pendingTitle = '';
        continue;
      }
      entries.add(ProfileEntry(videoId: videoId, title: pendingTitle));
      pendingTitle = '';
    }
    return entries;
  }
}

/// A single song reference inside a library profile.
class ProfileEntry {
  final String videoId;
  final String title;

  const ProfileEntry({required this.videoId, required this.title});
}
