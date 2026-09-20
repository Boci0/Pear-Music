import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/playback_actions.dart';
import '../services/player_service.dart';

/// App-wide playback keyboard shortcuts, YouTube style.
///
/// Two tiers:
///  * Single keys (Space/K play or pause, J/L seek, Shift+N/Shift+P skip).
///    These are ignored while a text field owns the keyboard, so typing in a
///    search box or a rename dialog can never poke playback.
///  * Ctrl+Alt combos and hardware media keys, which cannot be typed by
///    accident and therefore keep working even while typing.
///
/// Everything is inert until a song is loaded.
///
/// | Keys | Action |
/// | --- | --- |
/// | Space, K | Play or pause |
/// | J / L | Seek back / forward 10 seconds |
/// | , / . | Previous / next track |
/// | Shift+N / Shift+P | Previous / next track (alias) |
/// | Ctrl+Alt+Space, Media Play/Pause | Play or pause |
/// | Ctrl+Alt+N, Ctrl+Alt+PageDown, Media Next | Next track |
/// | Ctrl+Alt+B, Ctrl+Alt+PageUp, Media Previous | Previous track |
/// | Ctrl+Alt+L / Ctrl+Alt+J | Seek forward / back 10 seconds |
class PlaybackShortcuts extends StatelessWidget {
  final Widget child;

  const PlaybackShortcuts({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        // Single key shortcuts (YouTube style). Guarded: skipped while typing.
        SingleActivator(LogicalKeyboardKey.space):
            _PlaybackIntent(_PlaybackCommand.toggle, guarded: true),
        SingleActivator(LogicalKeyboardKey.keyK):
            _PlaybackIntent(_PlaybackCommand.toggle, guarded: true),
        SingleActivator(LogicalKeyboardKey.keyJ):
            _PlaybackIntent(_PlaybackCommand.seekBack, guarded: true),
        SingleActivator(LogicalKeyboardKey.keyL):
            _PlaybackIntent(_PlaybackCommand.seekForward, guarded: true),
        // Comma and period sit next to J/K/L, so skipping stays on the home
        // row; Shift+N / Shift+P stay as YouTube style aliases.
        SingleActivator(LogicalKeyboardKey.comma):
            _PlaybackIntent(_PlaybackCommand.previous, guarded: true),
        SingleActivator(LogicalKeyboardKey.period):
            _PlaybackIntent(_PlaybackCommand.next, guarded: true),
        SingleActivator(LogicalKeyboardKey.keyN, shift: true):
            _PlaybackIntent(_PlaybackCommand.next, guarded: true),
        SingleActivator(LogicalKeyboardKey.keyP, shift: true):
            _PlaybackIntent(_PlaybackCommand.previous, guarded: true),

        // Modifier combos. These cannot be typed by accident, so they stay
        // available even while a text field has focus.
        SingleActivator(LogicalKeyboardKey.space, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.toggle),
        SingleActivator(LogicalKeyboardKey.keyN, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.next),
        SingleActivator(LogicalKeyboardKey.pageDown, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.next),
        SingleActivator(LogicalKeyboardKey.keyB, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.previous),
        SingleActivator(LogicalKeyboardKey.pageUp, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.previous),
        SingleActivator(LogicalKeyboardKey.keyL, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.seekForward),
        SingleActivator(LogicalKeyboardKey.keyJ, control: true, alt: true):
            _PlaybackIntent(_PlaybackCommand.seekBack),

        // Hardware media keys arrive over 'peerm/media_keys' from the native
        // runner on Windows; these bindings stay as a fallback for platforms
        // that deliver them as regular key events.
        SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            _PlaybackIntent(_PlaybackCommand.toggle),
        SingleActivator(LogicalKeyboardKey.mediaTrackNext):
            _PlaybackIntent(_PlaybackCommand.next),
        SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
            _PlaybackIntent(_PlaybackCommand.previous),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PlaybackIntent: _PlaybackAction(player),
        },
        child: child,
      ),
    );
  }

  /// True while a text field (search box, rename dialog, and so on) owns the
  /// keyboard, which is when single key shortcuts must stay out of the way.
  static bool get _textFieldFocused {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}

enum _PlaybackCommand { toggle, next, previous, seekForward, seekBack }

class _PlaybackIntent extends Intent {
  final _PlaybackCommand command;

  /// When true the intent is ignored while a text field has focus.
  final bool guarded;

  const _PlaybackIntent(this.command, {this.guarded = false});
}

/// Runs playback commands, reporting itself disabled for guarded intents while
/// a text field has focus. Being disabled matters: [Shortcuts] returns
/// `ignored` (letting the keystroke reach the text field) only when the action
/// is not enabled. An action that merely does nothing still swallows the key.
class _PlaybackAction extends Action<_PlaybackIntent> {
  final PlayerService player;

  _PlaybackAction(this.player);

  @override
  bool isEnabled(_PlaybackIntent intent) =>
      !(intent.guarded && PlaybackShortcuts._textFieldFocused);

  @override
  Object? invoke(_PlaybackIntent intent) {
    switch (intent.command) {
      case _PlaybackCommand.toggle:
        PlaybackActions.toggle(player);
      case _PlaybackCommand.next:
        PlaybackActions.next(player);
      case _PlaybackCommand.previous:
        PlaybackActions.previous(player);
      case _PlaybackCommand.seekForward:
        PlaybackActions.seekForward(player);
      case _PlaybackCommand.seekBack:
        PlaybackActions.seekBack(player);
    }
    return null;
  }
}
