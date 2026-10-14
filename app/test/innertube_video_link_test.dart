import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/innertube_audio_engine.dart';

Map<String, dynamic> _response(List<Map<String, dynamic>> formats) => {
  'playabilityStatus': {'status': 'OK'},
  'responseContext': {'visitorData': 'v'},
  'streamingData': {'adaptiveFormats': formats},
};

Map<String, dynamic> _video(int height, String mime, String url) => {
  'mimeType': mime,
  'height': height,
  'bitrate': 1000,
  'url': url,
};

void main() {
  tearDown(InnerTubeAudioEngine.debugReset);

  test('the tallest picture within the cap is chosen, mp4 first on a tie', () async {
    InnerTubeAudioEngine.debugPlayerOverride = (id, visitor) async => _response([
      _video(1080, 'video/mp4; codecs="avc1"', 'https://v/1080'),
      _video(480, 'video/webm; codecs="vp9"', 'https://v/480-webm'),
      _video(480, 'video/mp4; codecs="avc1"', 'https://v/480-mp4'),
      _video(360, 'video/mp4; codecs="avc1"', 'https://v/360'),
      {
        'mimeType': 'audio/mp4; codecs="mp4a"',
        'url': 'https://v/audio',
      },
    ]);
    final link = await InnerTubeAudioEngine.videoLink('abc', maxHeight: 480);
    expect(link.url, 'https://v/480-mp4');
    expect(link.height, 480);
  });

  test('a response with no picture within the cap is a failure', () async {
    InnerTubeAudioEngine.debugPlayerOverride = (id, visitor) async =>
        _response([_video(1080, 'video/mp4; codecs="avc1"', 'https://v/1080')]);
    expect(
      () => InnerTubeAudioEngine.videoLink('abc', maxHeight: 480),
      throwsA(isA<InnerTubeFailure>()),
    );
  });
}
