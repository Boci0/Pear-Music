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

  test('the runtime row explains a missing Deno and shows a found one', () {
    expect(jsRuntimeSubtitle(null), contains('winget install DenoLand.Deno'));
    expect(jsRuntimeSubtitle('2.9.5'), 'Deno 2.9.5 found');
  });

  test('deno --version output is parsed', () {
    expect(
      YoutubeService.parseDenoVersion(
          'deno 2.9.5 (stable, release, x86_64-pc-windows-msvc)\nv8 14.0\ntypescript 5.9'),
      '2.9.5',
    );
    expect(YoutubeService.parseDenoVersion('not deno'), isNull);
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
