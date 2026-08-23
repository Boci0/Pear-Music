import 'dart:convert';

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
  final String title;
  final String fileName;
  final int size;
  final String checksum;
  final String? sourceDeviceId;
  final String? artwork;
  final DateTime addedAt;

  Song({
    required this.id,
    required this.title,
    required this.fileName,
    required this.size,
    required this.checksum,
    this.sourceDeviceId,
    this.artwork,
    required this.addedAt,
  });

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

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'fileName': fileName,
        'size': size,
        'checksum': checksum,
        'sourceDeviceId': sourceDeviceId,
        'artwork': artwork,
        'addedAt': addedAt.toIso8601String(),
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        id: json['id'] as String,
        title: json['title'] as String,
        fileName: json['fileName'] as String,
        size: json['size'] as int,
        checksum: json['checksum'] as String,
        sourceDeviceId: json['sourceDeviceId'] as String?,
        artwork: json['artwork'] as String?,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now(),
      );

  @override
  String toString() => 'Song($title)';
}

String songMetaJson(Song song) => jsonEncode(song.toJson());
