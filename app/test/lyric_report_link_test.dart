import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/lyrics_service.dart';

Song _song(String title, {String? artist}) => Song(
      id: 's',
      title: title,
      fileName: 's.m4a',
      size: 1,
      checksum: 'c',
      artist: artist,
      addedAt: DateTime(2026),
    );

void main() {
  test('issue link prefills only the song on the lyric timing form', () {
    final uri = LyricsService.timingIssueUri(_song('HUMBLE.', artist: 'Kendrick Lamar'));
    expect(uri.host, 'github.com');
    expect(uri.path, '/Boci0/Pear-Music/issues/new');
    expect(uri.queryParameters['template'], 'lyric-timing.yml');
    expect(uri.queryParameters['song'], 'HUMBLE. - Kendrick Lamar');
    expect(uri.queryParameters.keys, {'template', 'song'});
  });

  test('issue link does not repeat an artist the title already names', () {
    final uri = LyricsService.timingIssueUri(
        _song('HUMBLE. - Kendrick Lamar', artist: 'Kendrick Lamar'));
    expect(uri.queryParameters['song'], 'HUMBLE. - Kendrick Lamar');
  });

  test('issue link works for a song with no artist', () {
    final uri = LyricsService.timingIssueUri(_song('Local file'));
    expect(uri.queryParameters['song'], 'Local file');
  });
}
