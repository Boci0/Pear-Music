import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_service.dart';

/// A reliable file-sync transport that routes through the signaling server's
/// WebSocket connection instead of WebRTC.
///
/// It presents the same [RTCDataChannel] interface the [SyncService] already
/// uses, so the sync engine is unchanged. This is the fallback that keeps
/// Pear Music working on networks where WebRTC is unstable (e.g. phone hotspots).
///
/// Control messages travel as JSON text; binary chunks are sent as raw binary
/// WebSocket frames (no base64 → ~33% less bandwidth) with server acks for
/// backpressure (see [SignalingService.sendRelayBinary]). Sends are strictly
/// serialized per channel so a control message can never overtake a chunk and
/// `file_done` always arrives after the last chunk of its file.
class RelayDataChannel extends RTCDataChannel {
  RelayDataChannel({required this.peerId, required this.signaling});

  final String peerId;
  final SignalingService signaling;

  // FIFO of send tasks: preserves ordering (hello -> chunks -> file_done).
  final List<Future<void> Function()> _queue = [];
  bool _draining = false;

  // Inbound FIFO queue: serializes all received text and binary frames per channel
  // so chunks and control messages (e.g. file_done) are delivered to onMessage
  // in exact arrival order, even across asynchronous decryptions.
  final List<Future<void> Function()> _inboundQueue = [];
  bool _drainingInbound = false;

  @override
  RTCDataChannelState? get state => RTCDataChannelState.RTCDataChannelOpen;

  @override
  int? get id => -1;

  @override
  String? get label => 'pearmusic-relay';

  @override
  int? get bufferedAmount => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) {
    final completer = Completer<void>();
    _queue.add(() async {
      try {
        if (message.isBinary) {
          await signaling.sendRelayBinary(peerId, message.binary);
        } else {
          await signaling.sendRelay(peerId, {'t': 'text', 'd': message.text});
        }
      } catch (_) {
        // A failed send must never break the channel; the peer re-syncs on the
        // next manifest exchange.
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    _drain();
    return completer.future;
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    () async {
      try {
        while (_queue.isNotEmpty) {
          final task = _queue.removeAt(0);
          try {
            await task();
          } catch (e) {
            debugPrint('[relay] send task error: $e');
          }
        }
      } finally {
        _draining = false;
        if (_queue.isNotEmpty) {
          _drain();
        }
      }
    }();
  }

  void _drainInbound() {
    if (_drainingInbound) return;
    _drainingInbound = true;
    () async {
      try {
        while (_inboundQueue.isNotEmpty) {
          final task = _inboundQueue.removeAt(0);
          try {
            await task();
          } catch (e) {
            debugPrint('[relay] inbound task error: $e');
          }
        }
      } finally {
        _drainingInbound = false;
        if (_inboundQueue.isNotEmpty) {
          _drainInbound();
        }
      }
    }();
  }

  @override
  Future<void> close() async {
    _queue.clear();
    _inboundQueue.clear();
    _draining = false;
    _drainingInbound = false;
    onMessage = null;
  }

  /// Route an inbound relay text message (from the signaling stream) to
  /// [onMessage]. If the peer encrypted it (`e:1`), decrypt it with our shared
  /// E2E key first; un-decryptable/tampered messages are dropped, never
  /// surfaced.
  Future<void> handleRelay(Map<String, dynamic> data) async {
    debugPrint('[diag] handleRelay t=${data['t']} e=${data['e']} cbNull=${onMessage == null} dIsString=${data['d'] is String}');
    if (data['t'] != 'text') return;
    final completer = Completer<void>();
    _inboundQueue.add(() async {
      try {
        final cb = onMessage;
        if (cb == null) return;
        var text = data['d'] as String;
        if (data['e'] == 1) {
          final clear = await signaling.decryptTextFor(peerId, text);
          if (clear == null) {
            debugPrint('[diag] handleRelay DROPPED encrypted text (decrypt failed)');
            return;
          }
          text = utf8.decode(clear);
        }
        debugPrint('[diag] handleRelay delivering ${text.substring(0, text.length > 80 ? 80 : text.length)}');
        cb(RTCDataChannelMessage(text));
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    _drainInbound();
    return completer.future;
  }

  /// Route an inbound raw binary frame (a relayed chunk body) to [onMessage].
  /// When [encrypted] is true (from the `{t:'bin', e:1}` marker) it is
  /// decrypted with our shared E2E key first; failures are dropped.
  Future<void> handleRelayBinary(Uint8List bytes,
      {bool encrypted = false}) async {
    final completer = Completer<void>();
    _inboundQueue.add(() async {
      try {
        final cb = onMessage;
        if (cb == null) return;
        if (encrypted) {
          final clear = await signaling.decryptBinaryFor(peerId, bytes);
          if (clear == null) return;
          bytes = clear;
        }
        cb(RTCDataChannelMessage.fromBinary(bytes));
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    _drainInbound();
    return completer.future;
  }
}
