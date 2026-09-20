import '../models/song.dart';
import 'recommendation_service.dart';

/// Helpers for the portable "library profile" format.
///
/// A profile is an M3U playlist file that lists only songs originally added
/// from links: they carry a YouTube ID, so they can be re-fetched on any
/// device. Songs added from disk stay on the device that created them, so
/// they are excluded on export and never accepted on import.
///
/// Favorites survive the round trip through `#FAVORITE <videoId>` comment
/// lines placed after their entry. Favorited online-only songs (stream
/// references that are never downloaded) travel in a
/// `#PEARMUSIC-ONLINE-FAVORITES` section at the end of the file. M3U players
/// ignore unknown comments, so the file stays playable outside Pear Music.
class LibraryProfile {
  LibraryProfile._();

  static const String marker = '#PEARMUSIC-LIBRARY-PROFILE';
  static const String favoriteMarker = '#FAVORITE';
  static const String onlineFavoritesMarker = '#PEARMUSIC-ONLINE-FAVORITES';
  static const String artworkMarker = '#PEARMUSIC-ART';
  static final RegExp _videoIdTag = RegExp(r'\[([a-zA-Z0-9_-]{11})\]');

  /// Extracts the YouTube ID stored in a link-added song's file name.
  static String? videoIdOf(Song song) =>
      _videoIdTag.firstMatch(song.fileName)?.group(1);

  /// True when [content] carries the library profile marker. Playlist exports
  /// do not, so importers can reject the wrong kind of M3U up front.
  static bool isProfile(String content) {
    for (final raw in content.split(RegExp(r'\r?\n'))) {
      if (raw.trim() == marker) return true;
    }
    return false;
  }

  /// Builds the profile file content for [songs]. Local-only songs are
  /// skipped and duplicate YouTube IDs are collapsed (first occurrence wins,
  /// library order is kept). YouTube IDs in [favoriteVideoIds] are marked
  /// with a `#FAVORITE` line so the heart survives an import elsewhere.
  ///
  /// [onlineFavorites] are appended in a dedicated section after the
  /// playlist: they are stream-only references that import recreates as
  /// favorites instead of downloading. Returns null when there is nothing at
  /// all to export.
  static String? build(
    List<Song> songs, {
    Set<String> favoriteVideoIds = const <String>{},
    List<ProfileOnlineFavorite> onlineFavorites =
        const <ProfileOnlineFavorite>[],
  }) {
    final entries = <ProfileEntry>[];
    final seen = <String>{};
    for (final song in songs) {
      final videoId = videoIdOf(song);
      if (videoId == null || !seen.add(videoId)) continue;
      entries.add(ProfileEntry(videoId: videoId, title: song.title));
    }
    if (entries.isEmpty && onlineFavorites.isEmpty) return null;

    final buffer = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln(marker)
      ..writeln('#PLAYLIST:Pear Music Library');
    for (final entry in entries) {
      buffer.writeln('#EXTINF:-1,${entry.title}');
      buffer.writeln('https://www.youtube.com/watch?v=${entry.videoId}');
      if (favoriteVideoIds.contains(entry.videoId)) {
        buffer.writeln('$favoriteMarker ${entry.videoId}');
      }
    }
    if (onlineFavorites.isNotEmpty) {
      buffer.writeln(onlineFavoritesMarker);
      for (final fav in onlineFavorites) {
        if (fav.title.isNotEmpty) {
          buffer.writeln('#EXTINF:-1,${fav.title}');
        }
        final artwork = fav.artwork;
        if (artwork != null && artwork.isNotEmpty) {
          buffer.writeln('$artworkMarker $artwork');
        }
        buffer.writeln('https://www.youtube.com/watch?v=${fav.videoId}');
      }
    }
    return buffer.toString();
  }

  /// Parses [content] into ordered, de-duplicated entries. Lines without a
  /// YouTube link (comments, local paths) are ignored so nothing foreign can
  /// leak into the library. Entries after the online favorites section are
  /// not playlist items and are skipped here (see [parseOnlineFavorites]).
  static List<ProfileEntry> parse(String content) {
    final entries = <ProfileEntry>[];
    final seen = <String>{};
    var pendingTitle = '';
    for (final raw in content.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line == onlineFavoritesMarker) break;
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

  /// Extracts the YouTube IDs flagged as favorites by a profile
  /// (`#FAVORITE <videoId>` lines). Malformed markers are ignored.
  static Set<String> parseFavoriteIds(String content) {
    final ids = <String>{};
    for (final raw in content.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (!line.startsWith(favoriteMarker)) continue;
      final videoId = RecommendationService.extractVideoId(
        line.substring(favoriteMarker.length),
      );
      if (videoId != null) ids.add(videoId);
    }
    return ids;
  }

  /// Reads the online favorites section: stream-only songs with an optional
  /// title and artwork URL, recreated as favorites on import.
  static List<ProfileOnlineFavorite> parseOnlineFavorites(String content) {
    final favorites = <ProfileOnlineFavorite>[];
    final seen = <String>{};
    var inSection = false;
    var pendingTitle = '';
    String? pendingArtwork;
    for (final raw in content.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line == onlineFavoritesMarker) {
        inSection = true;
        continue;
      }
      if (!inSection) continue;
      if (line.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        pendingTitle = comma == -1 ? '' : line.substring(comma + 1).trim();
        continue;
      }
      if (line.startsWith(artworkMarker)) {
        pendingArtwork = line.substring(artworkMarker.length).trim();
        continue;
      }
      if (line.startsWith('#')) continue;
      final videoId = RecommendationService.extractVideoId(line);
      if (videoId == null || !seen.add(videoId)) {
        pendingTitle = '';
        pendingArtwork = null;
        continue;
      }
      favorites.add(ProfileOnlineFavorite(
        videoId: videoId,
        title: pendingTitle,
        artwork: pendingArtwork,
      ));
      pendingTitle = '';
      pendingArtwork = null;
    }
    return favorites;
  }
}

/// A favorited online-only song reference carried inside a profile.
class ProfileOnlineFavorite {
  final String videoId;
  final String title;
  final String? artwork;

  const ProfileOnlineFavorite({
    required this.videoId,
    this.title = '',
    this.artwork,
  });
}

/// A single song reference inside a library profile.
class ProfileEntry {
  final String videoId;
  final String title;

  const ProfileEntry({required this.videoId, required this.title});
}
