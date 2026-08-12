import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the private _YouTubeDialog from home_screen.dart exactly (same
/// widgets, same content) so we can reproduce its keyboard-in-landscape
/// RenderFlex overflow deterministically in a widget test.
class _MirrorDialog extends StatefulWidget {
  const _MirrorDialog({this.busy = false});
  final bool busy;
  @override
  State<_MirrorDialog> createState() => _MirrorDialogState();
}

class _MirrorDialogState extends State<_MirrorDialog> {
  final _urlController = TextEditingController();
  late final bool _busy = widget.busy;
  final String _status = 'Downloading…';
  final String? _error = null;
  final int _downloaded = 5;
  final int _total = 10;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Mirrors the fixed _YouTubeDialog: a Dialog whose whole body (including
    // the action buttons) is inside a SingleChildScrollView so it can never
    // RenderFlex-overflow when the keyboard shrinks the window in landscape.
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add from link', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                enabled: !_busy,
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(
                  labelText: 'YouTube or Spotify link',
                  hintText:
                      'https://www.youtube.com/watch?v=…  or  …/spotify.com/track/…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'YouTube links download the audio straight to this device. Spotify '
                'links are matched to their YouTube source (Spotify audio is '
                'DRM-protected), so either way it syncs to your paired devices '
                'with artwork.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _total > 0
                        ? (_downloaded / _total).clamp(0.0, 1.0)
                        : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (_total > 0)
                      Text(
                        '${_bytes(_downloaded)} / ${_bytes(_total)} '
                        '(${(_downloaded / _total * 100).clamp(0, 100).toStringAsFixed(0)}%)',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(_busy ? 'Cancel download' : 'Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : () {},
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Safely truncate an exception string for a failure message.
String _truncate(String? s) {
  if (s == null) return '';
  return s.length <= 400 ? s : s.substring(0, 400);
}

/// Pump the dialog inside a MaterialApp with the given viewport/keyboard
/// geometry, open it, and report whether a RenderFlex overflow was thrown.
Future<String?> _probe(
  WidgetTester tester, {
  required Size size,
  required double keyboard,
  bool busy = false,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);

  await tester.pumpWidget(MaterialApp(
    // Let the dialog keep its own theme but scale text like an accessibility
    // setting would.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => _MirrorDialog(busy: busy),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  final dynamic e = tester.takeException();
  if (e == null) return null;
  return e.toString();
}

/// Opens the dialog, then slides the soft keyboard in over a few frames (like
/// the real animation) to catch transient RenderFlex overflows.
Future<String?> _probeAnimatedKeyboard(
  WidgetTester tester, {
  required Size size,
  required double keyboard,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);

  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const _MirrorDialog(),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  // Slide the keyboard in: 0 → keyboard over ~8 frames.
  for (var i = 1; i <= 8; i++) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * i / 8);
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();

  final dynamic e = tester.takeException();
  if (e == null) return null;
  return e.toString();
}

void main() {
  // Common Android landscape phones (logical px), with keyboards taking
  // between 30% and 55% of the short side, in both idle and downloading
  // (busy → progress bar + status row visible) states. The last two include
  // extreme keyboards that make the actions bar taller than the dialog, which
  // is exactly the on-device failure (`scrollable: true` does not protect the
  // actions bar).
  const scenarios = <(Size, double, bool, double)>[
    (Size(640, 360), 200, false, 1.0),
    (Size(640, 360), 200, true, 1.0),
    (Size(640, 360), 160, true, 1.0),
    (Size(731, 411), 220, false, 1.0),
    (Size(731, 411), 220, true, 1.0),
    (Size(640, 360), 160, false, 1.3),
    (Size(640, 360), 160, true, 1.3),
    (Size(720, 320), 180, true, 1.0),
    (Size(640, 360), 270, false, 1.0),
    (Size(640, 360), 270, true, 1.0),
  ];

  for (final (size, keyboard, busy, textScale) in scenarios) {
    testWidgets(
        'landscape ${size.width}x${size.height} kb=$keyboard '
        'busy=$busy scale=$textScale: no overflow', (tester) async {
      final e = await _probe(tester,
          size: size, keyboard: keyboard, busy: busy, textScale: textScale);
      expect(e, isNull, reason: 'Expected no overflow, got: ${_truncate(e)}');
    });
  }

  testWidgets('landscape + animated keyboard slide-in: no transient overflow',
      (tester) async {
    final e = await _probeAnimatedKeyboard(tester,
        size: const Size(640, 360), keyboard: 270);
    expect(e, isNull, reason: 'Expected no overflow, got: ${_truncate(e)}');
  });
}
