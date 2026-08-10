import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persistent identity + settings for this device.
///
/// - [deviceId]: a random UUID generated once on first launch. It is what the
///   signaling server uses to identify this device and route pairing.
/// - [deviceName]: human readable name shown to other devices (editable).
/// - [serverUrl]: the signaling server WebSocket URL (editable in Settings).
class IdentityService {
  static const _deviceIdKey = 'peerm_device_id';
  static const _deviceNameKey = 'peerm_device_name';
  static const _serverUrlKey = 'peerm_server_url';
  static const _deviceSecretKey = 'peerm_device_secret';

  final SharedPreferences _prefs;
  late final String deviceId;
  late String deviceName;
  late String serverUrl;
  late String deviceSecret;

  IdentityService(this._prefs) {
    deviceId = _prefs.getString(_deviceIdKey) ?? _uuid();
    deviceName = _prefs.getString(_deviceNameKey) ?? _defaultName();
    serverUrl = _prefs.getString(_serverUrlKey) ?? 'ws://localhost:8080';
    deviceSecret = _prefs.getString(_deviceSecretKey) ?? '';

    if (_prefs.getString(_deviceIdKey) == null) {
      _prefs.setString(_deviceIdKey, deviceId);
    }
  }

  String _uuid() => const Uuid().v4();

  String _defaultName() {
    // Try to use the OS host/device name when available.
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty) return host;
    } catch (_) {}
    return 'My Device';
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    deviceName = trimmed;
    await _prefs.setString(_deviceNameKey, trimmed);
  }

  Future<void> setServerUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    serverUrl = trimmed;
    await _prefs.setString(_serverUrlKey, trimmed);
  }

  /// Persist the device-authentication secret the server issued on first
  /// registration. It is sent with every future `register` so a sniffed
  /// [deviceId] can't be used to impersonate this device.
  Future<void> setDeviceSecret(String secret) async {
    if (secret.isEmpty || secret == deviceSecret) return;
    deviceSecret = secret;
    await _prefs.setString(_deviceSecretKey, secret);
  }
}
