import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/recommendation_service.dart';

void main() {
  test('online songs keep the artist apart from the title', () {
    const item = RecommendationItem(
      videoId: 'abc',
      title: 'Some Title',
      artist: 'Some Artist',
    );
    final song = item.toSong();
    expect(song.title, 'Some Title - Some Artist');
    expect(song.artist, 'Some Artist');
    expect(song.titleOnly, 'Some Title');
  });

  test('a title that already names the artist is left whole', () {
    const item = RecommendationItem(
      videoId: 'abc',
      title: 'Some Artist - Some Title',
      artist: 'Some Artist',
    );
    final song = item.toSong();
    expect(song.title, 'Some Artist - Some Title');
    expect(song.titleOnly, 'Some Artist - Some Title');
  });

  test('the artist survives a JSON round trip and is optional', () {
    final song = RecommendationItem(
      videoId: 'abc',
      title: 'T',
      artist: 'A',
    ).toSong();
    expect(Song.fromJson(song.toJson()).artist, 'A');
    final legacy = song.toJson()..remove('artist');
    expect(Song.fromJson(legacy).artist, isNull);
    expect(Song.fromJson(legacy).titleOnly, song.title);
  });
}
