import 'player_service.dart';

/// Playback actions shared by the keyboard shortcuts and the hardware media
/// keys, so both paths behave identically. Every action is inert until a song
/// is loaded.
class PlaybackActions {
  PlaybackActions._();

  static const Duration seekStep = Duration(seconds: 10);

  static void toggle(PlayerService player) {
    if (player.hasLoaded) player.toggle();
  }

  static void next(PlayerService player) {
    if (player.hasLoaded) player.next(userAction: true);
  }

  static void previous(PlayerService player) {
    if (player.hasLoaded) player.previous();
  }

  static void seekForward(PlayerService player) => seekBy(player, seekStep);

  static void seekBack(PlayerService player) => seekBy(player, -seekStep);

  /// Moves the playhead by [delta], clamped to the track bounds. Does nothing
  /// while the current position is unknown.
  static void seekBy(PlayerService player, Duration delta) {
    final position = player.position;
    if (position == null) return;
    var target = position + delta;
    if (target < Duration.zero) target = Duration.zero;
    final duration = player.duration;
    if (duration != null && target > duration) target = duration;
    player.seek(target);
  }
}
