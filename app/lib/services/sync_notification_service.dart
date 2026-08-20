import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'sync_service.dart';

/// System notification service that displays an active progress bar in the
/// notification shade during song uploads / downloads and library sync.
class SyncNotificationService {
  SyncNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const int _notificationId = 8081;
  static const String _channelId = 'peerm_sync_channel';
  static const String _channelName = 'File Sync';

  static DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static Timer? _throttleTimer;
  static Timer? _autoCancelTimer;
  static bool _isShowing = false;

  /// Initialize platform notification channels. Safe to call on all platforms.
  static Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      const androidInit =
          AndroidInitializationSettings('@mipmap/ic_notification');
      const darwinInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      final linuxInit = LinuxInitializationSettings(
        defaultActionName: 'Open',
        defaultIcon: AssetsLinuxIcon('assets/pear_logo.png'),
      );
      final initSettings = InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
        linux: linuxInit,
      );

      await _plugin.initialize(
        settings: initSettings,
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[SyncNotificationService] init error: $e');
    }
  }

  /// Bind to [SyncService] to automatically show, update, and dismiss
  /// progress bar notifications based on [SyncService.batchState].
  static void bind(SyncService sync) {
    sync.addListener(() => _onSyncStateChanged(sync));
  }

  static void _onSyncStateChanged(SyncService sync) {
    if (!_initialized) return;
    final batch = sync.batchState;

    if (batch == null) {
      if (_isShowing) {
        _cancel();
      }
      return;
    }

    if (batch.isDone) {
      _showCompleted(batch);
      return;
    }

    _scheduleProgressUpdate(batch);
  }

  static void _scheduleProgressUpdate(SyncBatchState batch) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastUpdate);
    if (elapsed > const Duration(milliseconds: 250)) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _updateProgress(batch);
    } else {
      _throttleTimer ??= Timer(
        Duration(milliseconds: 250 - elapsed.inMilliseconds),
        () {
          _throttleTimer = null;
          _updateProgress(batch);
        },
      );
    }
  }

  static int _lastMaxPercent = 0;

  static Future<void> _updateProgress(SyncBatchState batch) async {
    _lastUpdate = DateTime.now();
    _autoCancelTimer?.cancel();
    _autoCancelTimer = null;
    _isShowing = true;

    final totalSongs = batch.totalSongs;
    final completedSongs = batch.completedSongs;
    final activeFraction = batch.progressFraction;
    final percent = (activeFraction * 100).clamp(0, 100).toInt();

    if (completedSongs == 0 && percent == 0) {
      _lastMaxPercent = percent;
    } else if (percent > _lastMaxPercent) {
      _lastMaxPercent = percent;
    }
    final effectivePercent = _lastMaxPercent.clamp(0, 100);

    final isSingle = totalSongs <= 1;
    final title = isSingle
        ? (batch.isDownload ? 'Downloading Song' : 'Uploading Song')
        : 'Syncing Library ($completedSongs of $totalSongs songs)';

    final songName = batch.activeSongTitle.isNotEmpty
        ? batch.activeSongTitle
        : (batch.isDownload ? 'Receiving music' : 'Sending music');

    final completedMb =
        (batch.completedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (batch.totalBytes / (1024 * 1024)).toStringAsFixed(1);
    final body = batch.totalBytes > 0
        ? '$songName ($completedMb / $totalMb MB)'
        : '$songName ($effectivePercent%)';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Shows file sync and transfer progress',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: effectivePercent,
      ongoing: true,
      onlyAlertOnce: true,
      autoCancel: false,
      icon: '@mipmap/ic_notification',
    );

    final details = NotificationDetails(android: androidDetails);

    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('[SyncNotificationService] show error: $e');
    }
  }

  static Future<void> _showCompleted(SyncBatchState batch) async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _lastUpdate = DateTime.now();
    _isShowing = true;

    final totalSongs = batch.totalSongs;
    final title = 'Sync Complete';
    final body = '$totalSongs song${totalSongs == 1 ? '' : 's'} synced';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Shows file sync and transfer progress',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: false,
      ongoing: false,
      onlyAlertOnce: true,
      autoCancel: true,
      icon: '@mipmap/ic_notification',
    );

    final details = NotificationDetails(android: androidDetails);

    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('[SyncNotificationService] show error: $e');
    }

    _autoCancelTimer?.cancel();
    _autoCancelTimer = Timer(const Duration(seconds: 4), () {
      _cancel();
    });
  }

  static Future<void> _cancel() async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _autoCancelTimer?.cancel();
    _autoCancelTimer = null;
    _isShowing = false;
    _lastMaxPercent = 0;
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {}
  }
}
