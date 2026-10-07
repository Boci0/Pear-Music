import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/audio_engine_card.dart';

void main() {
  test('every update status has a plain-language message', () {
    for (final status in YtDlpUpdateStatus.values) {
      final message = audioEngineResultMessage(YtDlpUpdateResult(status, '2026.08.19'));
      expect(message, isNotEmpty, reason: '$status');
    }
  });

  test('messages carry the version where it helps', () {
    expect(
      audioEngineResultMessage(
          const YtDlpUpdateResult(YtDlpUpdateStatus.updated, '2026.08.19')),
      contains('2026.08.19'),
    );
    expect(
      audioEngineResultMessage(
          const YtDlpUpdateResult(YtDlpUpdateStatus.upToDate, '')),
      'yt-dlp is already up to date.',
    );
  });
}
