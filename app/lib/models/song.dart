import 'dart:convert';

import '../services/text_repair.dart';

/// A music file in the local library.
///
/// [sourceDeviceId] is `null` when the song was added directly on this device.
/// When the song was received from a paired peer, it holds that peer's
/// `deviceId` — and the song is removed automatically when that peer is
/// un-paired.
///
/// [artwork] is an optional base64-encoded JPEG thumbnail (e.g. scraped from
/// YouTube). It travels inside [toJson], so it syncs to peers automatically
/// with no extra file-transfer protocol.
///
/// The Song model deliberately does NOT retain decoded artwork bytes in memory.
/// Decoding is handled by [ArtworkPalette.bytes] with a bounded LRU cache, so
/// a large library doesn't balloon RAM with per-song decoded bitmaps.
class Song {
  final String id;

  /// The display title. Code-page decoding mistakes (mojibake) are repaired
  /// here (see [TextRepair]), so every path that builds a [Song] shows the
  /// real characters, including titles restored from an older build's data.
  final String title;
  final String fileName;
  final int size;
  final String checksum;
  final String? sourceDeviceId;
  final String? artwork;

  /// The artist, when known (online songs); [title] then ends with
  /// ` - artist` unless the title already named them.
  final String? artist;

  /// A live stream (no length, no file): rows mark it LIVE. Kept with the
  /// song so the queue, history and favourites show it too.
  final bool isLive;

  /// Play length, once known. Null for older entries and live streams.
  final int? durationMs;
  final DateTime addedAt;
  late final String lowerTitle = title.toLowerCase();
  late final String lowerArtist = (artist ?? '').toLowerCase();

  Song({
    required this.id,
    required String title,
    required String fileName,
    required this.size,
    required this.checksum,
    this.sourceDeviceId,
    this.artwork,
    String? artist,
    this.isLive = false,
    this.durationMs,
    required this.addedAt,
  })  : title = TextRepair.title(title),
        // A stream reference's file name is just its title plus the video id,
        // so it heals with the title. Local file names are real paths and are
        // never touched.
        fileName = id.startsWith('stream_')
            ? TextRepair.title(fileName)
            : fileName,
        artist = artist == null || artist.isEmpty
            ? artist
            : TextRepair.title(artist);

  /// [title] without the ` - artist` suffix added for online songs, for
  /// places that show the artist on its own line.
  String get titleOnly {
    final a = artist;
    if (a == null || a.isEmpty) return title;
    final suffix = ' - $a';
    return title.endsWith(suffix) && title.length > suffix.length
        ? title.substring(0, title.length - suffix.length)
        : title;
  }

  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot == -1 ? 'mp3' : fileName.substring(dot + 1).toLowerCase();
  }

  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// This song with its play length set.
  Song withDuration(int ms) => Song(
        id: id,
        title: title,
        fileName: fileName,
        size: size,
        checksum: checksum,
        sourceDeviceId: sourceDeviceId,
        artwork: artwork,
        artist: artist,
        isLive: isLive,
        durationMs: ms,
        addedAt: addedAt,
      );

  /// "3:42", or "1:02:05" past an hour; null while the length is unknown.
  String? get durationLabel {
    final ms = durationMs;
    if (ms == null || ms <= 0) return null;
    final d = Duration(milliseconds: ms);
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (d.inHours == 0) return '${d.inMinutes}:$ss';
    final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    return '${d.inHours}:$mm:$ss';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'fileName': fileName,
        'size': size,
        'checksum': checksum,
        'sourceDeviceId': sourceDeviceId,
        'artwork': artwork,
        if (artist != null) 'artist': artist,
        if (isLive) 'isLive': true,
        if (durationMs != null) 'durationMs': durationMs,
        'addedAt': addedAt.toIso8601String(),
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        id: json['id'] as String,
        title: json['title'] as String,
        fileName: json['fileName'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        checksum: json['checksum'] as String? ?? '',
        sourceDeviceId: json['sourceDeviceId'] as String?,
        artwork: json['artwork'] as String?,
        artist: json['artist'] as String?,
        isLive: json['isLive'] == true,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now(),
      );

  @override
  String toString() => 'Song($title)';
}

String songMetaJson(Song song) => jsonEncode(song.toJson());
