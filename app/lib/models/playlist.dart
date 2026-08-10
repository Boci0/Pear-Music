/// A named, ordered list of song IDs from the local library.
///
/// [updatedAt] drives the two-way merge: when two paired devices edit the same
/// playlist, the most recently edited version wins. The device whose copy is
/// older re-broadcasts its state back to the peer.
class Playlist {
  final String id;
  String name;
  final List<String> songIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  Playlist({
    required this.id,
    required this.name,
    required this.songIds,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  Playlist copyWith({String? name, List<String>? songIds, DateTime? updatedAt}) =>
      Playlist(
        id: id,
        name: name ?? this.name,
        songIds: songIds ?? this.songIds,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songIds': songIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final createdAt =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      songIds: (json['songIds'] as List? ?? []).whereType<String>().toList(),
      createdAt: createdAt,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          createdAt,
    );
  }

  @override
  String toString() => 'Playlist($name, ${songIds.length} songs)';
}
