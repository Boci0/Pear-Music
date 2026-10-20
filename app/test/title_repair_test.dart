import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/recommendation_service.dart';
import 'package:peerm_app/services/text_repair.dart';
import 'package:peerm_app/services/youtube_search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows-1252's printable characters for the bytes 0x80-0x9F, the decoder
/// that made the mojibake these tests feed back in.
const Map<int, int> _cp1252Chars = {
  0x80: 0x20AC,
  0x82: 0x201A,
  0x83: 0x0192,
  0x84: 0x201E,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02C6,
  0x89: 0x2030,
  0x8A: 0x0160,
  0x8B: 0x2039,
  0x8C: 0x0152,
  0x8E: 0x017D,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201C,
  0x94: 0x201D,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02DC,
  0x99: 0x2122,
  0x9A: 0x0161,
  0x9B: 0x203A,
  0x9C: 0x0153,
  0x9E: 0x017E,
  0x9F: 0x0178,
};

/// [text] after [levels] rounds of "UTF-8 bytes decoded with cp1252", the
/// mistake older builds made. The real titles on the laptop came back exactly
/// like this at three levels.
String _garble(String text, int levels) {
  var out = text;
  for (var level = 0; level < levels; level++) {
    out = String.fromCharCodes([
      for (final byte in utf8.encode(out)) _cp1252Chars[byte] ?? byte,
    ]);
  }
  return out;
}

Map<String, dynamic> _storedSong({
  required String id,
  required String title,
  bool favorite = false,
}) =>
    {
      'id': id,
      'title': title,
      'fileName': '$title [${id.replaceFirst('stream_', '')}].m4a',
      'size': 1000,
      'checksum': id,
      'sourceDeviceId': 'stream',
      'addedAt': '2026-09-21T19:28:00.795694',
      if (favorite) 'artist': 'YOASOBI',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TextRepair', () {
    test('reverses one, two and three code-page decodes', () {
      const titles = [
        'あの夢をなぞって - YOASOBI',
        '百花繚乱 - In Bloom - Lilas',
        'パズル - 幾田りら',
        'ミニオリジナル - Tsunomaki Watame',
        '미완성 (Puzzle Piece) - KickFlip',
        'سورة يس',
        'Mládková - Daniela',
        'Café del Mar',
        '📚 lofi beats to study to',
        'Operation Deepness - 星團音樂',
      ];
      for (final title in titles) {
        for (var levels = 1; levels <= 3; levels++) {
          final broken = _garble(title, levels);
          expect(broken, isNot(title), reason: 'levels=$levels "$title"');
          expect(TextRepair.title(broken), title,
              reason: 'levels=$levels "$title"');
        }
      }
    });

    test('repairs a real triple-encoded title from the app data', () {
      // Copied from peerm_known_online_songs on the laptop, whose UTF-8 had
      // been decoded as cp1252 three times. Written with escapes because the
      // middle levels carry control characters.
      const stored = 'ÃƒÂ£Ã‚Â\u0081Ã¢â‚¬Å¡ÃƒÂ£Ã‚Â\u0081Ã‚Â®ÃƒÂ¥Ã‚Â¤Ã‚Â¢'
          'ÃƒÂ£Ã¢â‚¬Å¡Ã¢â‚¬â„¢ÃƒÂ£Ã‚Â\u0081Ã‚ÂªÃƒÂ£Ã‚Â\u0081Ã…Â¾ÃƒÂ£Ã‚Â\u0081'
          'Ã‚Â£ÃƒÂ£Ã‚Â\u0081Ã‚Â¦ - YOASOBI';
      expect(TextRepair.title(stored), 'あの夢をなぞって - YOASOBI');
    });

    test('leaves healthy titles alone', () {
      const titles = [
        '',
        'Never Gonna Give You Up',
        'ハルジオン - YOASOBI',
        '夏に咲く - Vaundy',
        '봄날 - BTS',
        'سورة يس | Relaxing voice',
        '🎃 spooky lofi to get chills to',
        'lofi hip hop radio – beats to sleep/study/relax to ☕',
        'H・A・N・A・B・I 〜君がいた夏〜 - H.A.N.A.B.I',
        'Mládková - Daniela',
        'Café del Mar',
      ];
      for (final title in titles) {
        expect(TextRepair.title(title), title);
      }
    });

    test('repair is idempotent', () {
      final broken = _garble('群青 - YOASOBI', 3);
      final once = TextRepair.title(broken);
      expect(TextRepair.title(once), once);
    });

    test('an accented title is not mistaken for broken bytes', () {
      // Healthy single characters whose lone bytes are not valid UTF-8.
      for (final title in ['é', '✓', '£', '©', '\u00C3', '\u00C2']) {
        expect(TextRepair.title(title), title);
      }
    });
  });

  group('repair at the model boundary', () {
    test('Song repairs its title and artist', () {
      final song = Song(
        id: 'stream_abc',
        title: _garble('群青 - 塞壬唱片-MSR', 3),
        fileName: 'x.m4a',
        size: 1,
        checksum: 'stream_abc',
        artist: _garble('塞壬唱片-MSR', 3),
        addedAt: DateTime(2026, 9, 21),
      );
      expect(song.title, '群青 - 塞壬唱片-MSR');
      expect(song.artist, '塞壬唱片-MSR');
    });

    test('search and recommendation items repair their titles', () {
      final item = RecommendationItem(
        videoId: 'a',
        title: _garble('フリーフォール (Extended Mix)', 2),
        artist: _garble('Zekk', 2),
      );
      expect(item.title, 'フリーフォール (Extended Mix)');
      expect(item.toSong().title, 'フリーフォール (Extended Mix) - Zekk');

      final result = YouTubeSearchResult(
        videoId: 'b',
        title: _garble('ハルジオン', 3),
        author: 'YOASOBI',
      );
      expect(result.title, 'ハルジオン');
      expect(result.toSong().title, 'ハルジオン - YOASOBI');
    });
  });

  group('persisted online songs heal on load', () {
    test('garbled known and favorite songs are written back repaired',
        () async {
      final knownTitle = _garble('群青 - YOASOBI', 3);
      final favoriteTitle = _garble('フリーフォール (Extended Mix) - Zekk', 3);
      SharedPreferences.setMockInitialValues({
        'flutter.peerm_favorite_song_ids': ['stream_fav'],
        'flutter.peerm_known_online_songs': jsonEncode({
          'stream_known': _storedSong(id: 'stream_known', title: knownTitle),
        }),
        'flutter.peerm_favorite_online_songs': jsonEncode({
          'stream_fav': _storedSong(
            id: 'stream_fav',
            title: favoriteTitle,
            favorite: true,
          ),
        }),
      });
      final prefs = await SharedPreferences.getInstance();

      final identity = IdentityService(prefs);

      expect(identity.findOnlineSong('stream_known')?.title, '群青 - YOASOBI');
      expect(
        identity.findFavoriteOnlineSong('stream_fav')?.title,
        'フリーフォール (Extended Mix) - Zekk',
      );
      // The healed titles are persisted, so the history and favourites rows
      // read clean text from disk on the next launch too.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        prefs.getString('peerm_known_online_songs'),
        contains('群青 - YOASOBI'),
      );
      expect(
        prefs.getString('peerm_favorite_online_songs'),
        contains('フリーフォール (Extended Mix) - Zekk'),
      );
      expect(
        prefs.getString('peerm_known_online_songs'),
        isNot(contains('\u00C3')),
      );
    });
  });
}
