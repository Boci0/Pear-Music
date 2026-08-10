import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persistent identity + settings for this device.
///
/// - [deviceId]: a random UUID generated once on first launch. It is what the
///   signaling server uses to identify this device and route pairing.
/// - [deviceName]: human readable name shown to other devices (editable).
/// - [serverUrl]: the signaling server WebSocket URL this device connects to.
/// - [isHost]: whether THIS device is the designated host (runs the embedded
///   server). The "last online" device is the host; others are clients that
///   connect to it. Persisted so the role survives restarts.
/// - [pairedDeviceIds]: the device IDs this device is paired with, persisted
///   locally so a NEW host (after failover) can be told about the pairing.
class IdentityService {
  static const _deviceIdKey = 'peerm_device_id';
  static const _deviceNameKey = 'peerm_device_name';
  static const _serverUrlKey = 'peerm_server_url';
  static const _deviceSecretKey = 'peerm_device_secret';
  static const _isHostKey = 'peerm_is_host';
  static const _pairedIdsKey = 'peerm_paired_device_ids';

  final SharedPreferences _prefs;
  late final String deviceId;
  late String deviceName;
  late String serverUrl;
  late String deviceSecret;
  late bool isHost;
  late Map<String, String> _paired; // deviceId -> last known name

  IdentityService(this._prefs) {
    deviceId = _prefs.getString(_deviceIdKey) ?? _uuid();
    deviceName = _prefs.getString(_deviceNameKey) ?? _defaultName();
    serverUrl = _prefs.getString(_serverUrlKey) ?? 'ws://localhost:8080';
    deviceSecret = _prefs.getString(_deviceSecretKey) ?? '';
    // A fresh device is its own host; it becomes a client only after another
    // host is found (or the other device defers to it).
    isHost = _prefs.getBool(_isHostKey) ?? true;
    _paired = _decodePaired(_prefs.getString(_pairedIdsKey));

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

  Map<String, String> _decodePaired(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        return d.map((k, v) => MapEntry('$k', '$v'));
      }
      if (d is List) {
        // Legacy format: a plain array of ids (no names known).
        return {for (final id in d.whereType<String>()) id: ''};
      }
    } catch (_) {}
    return {};
  }

  /// The device IDs this device is paired with (read-only view).
  List<String> get pairedDeviceIds => _paired.keys.toList();

  /// Paired device IDs with their last-known names (id -> name). Sent to a new
  /// host on register so it can restore the pairing WITH names after failover.
  Map<String, String> get pairedDeviceNames => Map.unmodifiable(_paired);

  /// Replace the known paired-device list (e.g. from the server's `state`).
  Future<void> setPairedDevices(
      Iterable<MapEntry<String, String>> entries) async {
    final next = <String, String>{
      for (final e in entries)
        if (e.key.isNotEmpty) e.key: e.value,
    };
    _paired = next;
    await _prefs.setString(_pairedIdsKey, jsonEncode(next));
  }

  Future<void> addPairedDevice(String id, {String name = ''}) async {
    if (id.isEmpty) return;
    if (_paired.containsKey(id)) {
      if (name.isNotEmpty && _paired[id] != name) {
        _paired[id] = name;
        await _prefs.setString(_pairedIdsKey, jsonEncode(_paired));
      }
      return;
    }
    _paired[id] = name;
    await _prefs.setString(_pairedIdsKey, jsonEncode(_paired));
  }

  Future<void> removePairedDevice(String id) async {
    if (!_paired.containsKey(id)) return;
    _paired.remove(id);
    await _prefs.setString(_pairedIdsKey, jsonEncode(_paired));
  }

  /// Set whether this device is the host (runs the embedded server).
  Future<void> setIsHost(bool value) async {
    if (value == isHost) return;
    isHost = value;
    await _prefs.setBool(_isHostKey, value);
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

  /// Forget the device-auth secret. Used after an `unauthorized` rejection:
  /// the stored secret was issued by a PREVIOUS host's server and is stale
  /// against the current host, so we clear it and reconnect with an empty
  /// secret, which makes the server re-bind a fresh one (never locks out).
  void clearDeviceSecret() {
    deviceSecret = '';
    unawaited(_prefs.setString(_deviceSecretKey, ''));
  }
}
