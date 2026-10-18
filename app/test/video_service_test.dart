import 'dart:ui' show Rect;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/widgets/player/player_fullscreen.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/video_service.dart';
import 'package:peerm_app/services/youtube_service.dart';

Song _song(String fileName, {String? source, bool live = false}) => Song(
  id: fileName,
  title: fileName,
  fileName: fileName,
  size: 1,
  checksum: '',
  sourceDeviceId: source,
  isLive: live,
  addedAt: DateTime(2026),
);

void main() {
  test('only local files in a video container may have a picture', () {
    expect(VideoService.mayHaveVideo(_song('a.mp4')), isTrue);
    expect(VideoService.mayHaveVideo(_song('a.MKV')), isTrue);
    expect(VideoService.mayHaveVideo(_song('a.mp3')), isFalse);
    expect(VideoService.mayHaveVideo(_song('a.m4a')), isFalse);
    // A cached stream's audio is stored as .mp4/.webm and has no picture.
    expect(VideoService.mayHaveVideo(_song('a.mp4', source: 'stream')), isFalse);
    expect(VideoService.mayHaveVideo(_song('a.mp4', live: true)), isFalse);
  });

  test('an audio download is offered a picture through the id in its name', () {
    const id = 'dQw4w9WgXcQ';
    final audio = _song('0d9b [$id].m4a');
    expect(VideoService.downloadVideoId(audio), id);
    expect(VideoService.mayHaveVideo(audio), isTrue);
    expect(VideoService.pictureStreamId(audio), id);
    // No id in the name, no picture to fetch.
    expect(VideoService.downloadVideoId(_song('0d9b.m4a')), isNull);
    expect(VideoService.mayHaveVideo(_song('0d9b.mp3')), isFalse);
    // A video file plays its own picture, id or not.
    final video = _song('0d9b [$id].mp4');
    expect(VideoService.mayHaveVideo(video), isTrue);
    expect(VideoService.pictureStreamId(video), isNull);
    expect(VideoService.downloadVideoId(_song('a [$id].m4a', live: true)), isNull);
  });

  test('a video download asks for a joinable H.264 picture within the height', () {
    final format = YoutubeService.videoDownloadFormat(720);
    expect(format.startsWith('bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]'), isTrue);
    // Without ffmpeg's join there is still a ready-made file to fall back on.
    expect(format, contains('/b[height<=720]'));
    expect(format, isNot(contains('1080')));
  });

  test('a streamed song is looked up by its video id, a live one is not', () {
    Song stream({bool live = false}) => Song(
      id: 'stream_dQw4w9WgXcQ',
      title: 't',
      fileName: 't [dQw4w9WgXcQ].m4a',
      size: 0,
      checksum: 'stream_dQw4w9WgXcQ',
      sourceDeviceId: 'stream',
      isLive: live,
      addedAt: DateTime(2026),
    );
    expect(VideoService.streamVideoId(stream()), 'dQw4w9WgXcQ');
    expect(VideoService.mayHaveVideo(stream()), isTrue);
    expect(VideoService.mayHaveVideo(stream(live: true)), isFalse);
  });

  test('the picture is pulled back only past the drift allowance', () {
    const t = Duration(seconds: 10);
    expect(VideoService.needsSeek(t, t), isFalse);
    expect(VideoService.needsSeek(t + const Duration(milliseconds: 300), t), isFalse);
    expect(VideoService.needsSeek(t + const Duration(milliseconds: 400), t), isTrue);
    expect(VideoService.needsSeek(t - const Duration(milliseconds: 400), t), isTrue);
  });

  test('a seek still landing is not asked for again every tick', () {
    const audio = Duration(seconds: 60);
    const video = Duration(seconds: 200);
    // Nothing pending: pull the picture back.
    expect(VideoService.shouldSeek(video: video, audio: audio), isTrue);
    // A seek to 59.7 s was issued 0.6 s ago and audio has moved on with it.
    expect(
      VideoService.shouldSeek(
        video: video,
        audio: const Duration(milliseconds: 60300),
        lastTarget: const Duration(milliseconds: 59700),
        sinceLast: const Duration(milliseconds: 600),
      ),
      isFalse,
    );
    // The listener rewound again meanwhile: seek at once.
    expect(
      VideoService.shouldSeek(
        video: video,
        audio: const Duration(seconds: 20),
        lastTarget: const Duration(milliseconds: 59700),
        sinceLast: const Duration(milliseconds: 600),
      ),
      isTrue,
    );
    // The seek never landed within the grace: try again.
    expect(
      VideoService.shouldSeek(
        video: video,
        audio: const Duration(milliseconds: 64000),
        lastTarget: const Duration(milliseconds: 59700),
        sinceLast: const Duration(seconds: 5),
      ),
      isTrue,
    );
  });

  group('black bars', () {
    Uint8List frame(int w, int h, bool Function(int x, int y) lit) {
      final out = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final v = lit(x, y) ? 200 : 0;
          out[i] = v;
          out[i + 1] = v;
          out[i + 2] = v;
          out[i + 3] = 255;
        }
      }
      return out;
    }

    test('a square cover on a wide black canvas is cut to the cover', () {
      // 160x90 with the cover in the middle 90 columns.
      final rgba = frame(160, 90, (x, y) => x >= 35 && x < 125);
      final scan = VideoService.scanBars(rgba, 160, 90);
      expect(scan.conclusive, isTrue);
      final crop = scan.crop!;
      expect(crop.left, closeTo(35 / 160, 0.03));
      expect(crop.right, closeTo(125 / 160, 0.03));
      expect(crop.top, 0);
      expect(crop.bottom, 1);
    });

    test('a frame lit edge to edge is left alone', () {
      final scan = VideoService.scanBars(frame(160, 90, (x, y) => true), 160, 90);
      expect(scan.conclusive, isTrue);
      expect(scan.crop, isNull);
    });

    test('a black frame is not an answer yet', () {
      final scan = VideoService.scanBars(frame(160, 90, (x, y) => false), 160, 90);
      expect(scan.conclusive, isFalse);
    });
  });

  group('fullscreen fit', () {
    test('a close shape fills the screen, a very different one fits', () {
      // 16:9 picture on a 16:10 tablet, a 4:3 window and a 16:9 monitor.
      expect(PlayerFullscreenPage.fillsByDefault(16 / 9, 16 / 10), isTrue);
      expect(PlayerFullscreenPage.fillsByDefault(16 / 9, 4 / 3), isTrue);
      expect(PlayerFullscreenPage.fillsByDefault(16 / 9, 16 / 9), isTrue);
      // The same picture on a 20:9 phone would lose a fifth of its height.
      expect(PlayerFullscreenPage.fillsByDefault(16 / 9, 20 / 9), isTrue);
      // A portrait window would lose most of it.
      expect(PlayerFullscreenPage.fillsByDefault(16 / 9, 9 / 16), isFalse);
    });
  });

  group('quality', () {
    test('a chosen height is used as it is', () {
      for (final h in [360, 480, 720, 1080]) {
        expect(VideoService.pickHeight(setting: h, metered: true), h);
        expect(VideoService.pickHeight(setting: h, metered: false), h);
      }
    });

    test('auto is small on mobile data and full otherwise', () {
      expect(VideoService.pickHeight(setting: 0, metered: true), 360);
      expect(VideoService.pickHeight(setting: 0, metered: false), 720);
    });

    test('an unknown saved value falls back to auto', () {
      expect(VideoService.pickHeight(setting: 2160, metered: true), 360);
      expect(VideoService.pickHeight(setting: -1, metered: false), 720);
    });
  });

  test('bar scans must agree before anything is cut', () {
    const a = Rect.fromLTRB(0.22, 0, 0.78, 1);
    expect(VideoService.cropsAgree(a, const Rect.fromLTRB(0.221, 0, 0.779, 1)),
        isTrue);
    expect(VideoService.cropsAgree(a, const Rect.fromLTRB(0.10, 0, 0.90, 1)),
        isFalse);
    expect(VideoService.cropsAgree(a, const Rect.fromLTRB(0, 0, 1, 1)), isFalse);
  });
}
