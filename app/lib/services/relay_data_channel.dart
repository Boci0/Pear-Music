import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  // FIFO of send tasks: preserves ordering (hello → chunks → file_done).
  final List<Future<void> Function()> _queue = [];
  bool _draining = false;

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
    Future<void>(() async {
      try {
        while (_queue.isNotEmpty) {
          final task = _queue.removeAt(0);
          await task();
        }
      } finally {
        _draining = false;
      }
    });
  }

  @override
  Future<void> close() async {}

  /// Route an inbound relay text message (from the signaling stream) to
  /// [onMessage]. If the peer encrypted it (`e:1`), decrypt it with our shared
  /// E2E key first; un-decryptable/tampered messages are dropped, never
  /// surfaced.
  Future<void> handleRelay(Map<String, dynamic> data) async {
    if (data['t'] != 'text') return;
    final cb = onMessage;
    if (cb == null) return;
    var text = data['d'] as String;
    if (data['e'] == 1) {
      final clear = await signaling.decryptTextFor(peerId, text);
      if (clear == null) return;
      text = utf8.decode(clear);
    }
    cb(RTCDataChannelMessage(text));
  }

  /// Route an inbound raw binary frame (a relayed chunk body) to [onMessage].
  /// When [encrypted] is true (from the `{t:'bin', e:1}` marker) it is
  /// decrypted with our shared E2E key first; failures are dropped.
  Future<void> handleRelayBinary(Uint8List bytes,
      {bool encrypted = false}) async {
    final cb = onMessage;
    if (cb == null) return;
    if (encrypted) {
      final clear = await signaling.decryptBinaryFor(peerId, bytes);
      if (clear == null) return;
      bytes = clear;
    }
    cb(RTCDataChannelMessage.fromBinary(bytes));
  }
}
