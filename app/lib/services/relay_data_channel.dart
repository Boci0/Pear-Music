import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'signaling_service.dart';

// ignore_for_file: constant_identifier_names

/// Channel state compatibility enum.
enum RTCDataChannelState {
  RTCDataChannelConnecting,
  RTCDataChannelOpen,
  RTCDataChannelClosing,
  RTCDataChannelClosed,
}

/// Channel message representation for sync transport.
class RTCDataChannelMessage {
  final String? _text;
  final Uint8List? _binary;
  final bool isBinary;

  RTCDataChannelMessage(String text)
      : _text = text,
        _binary = null,
        isBinary = false;

  RTCDataChannelMessage.fromBinary(Uint8List binary)
      : _text = null,
        _binary = binary,
        isBinary = true;

  String get text => _text ?? '';
  Uint8List get binary => _binary ?? Uint8List(0);
}

typedef RTCDataChannelMessageCallback = void Function(RTCDataChannelMessage message);
typedef RTCDataChannelStateCallback = void Function(RTCDataChannelState state);

/// Abstract data channel interface.
abstract class RTCDataChannel {
  RTCDataChannelMessageCallback? onMessage;
  RTCDataChannelStateCallback? onDataChannelState;
  void Function(int currentAmount)? onBufferedAmountLow;
  int? bufferedAmountLowThreshold;
  RTCDataChannelState? get state;
  int? get id;
  String? get label;
  int? get bufferedAmount;
  Future<void> send(RTCDataChannelMessage message);
  Future<void> close();
}

/// A reliable file-sync transport that routes through the signaling server's
/// WebSocket connection with end-to-end encryption.
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

  /// Sent the plaintext fallback request at least once this channel session,
  /// so a flood of undecryptable frames does not re-send it every chunk.
  bool _fallbackRequested = false;

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
          await Future<void>.delayed(Duration.zero);
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
          await Future<void>.delayed(Duration.zero);
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
    _fallbackRequested = false;
    onMessage = null;
  }

  /// Route an inbound relay text message (from the signaling stream) to
  /// [onMessage]. If the peer encrypted it (`e:1`), decrypt it with our shared
  /// E2E key first; un-decryptable/tampered messages are dropped, never
  /// surfaced.
  Future<void> handleRelay(Map<String, dynamic> data) async {
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
            // Do NOT wipe the peer key here (that stranded both devices in an
            // endless retransmission storm). Tell the peer to send plaintext
            // instead once it has crossed the consecutive-failure threshold.
            _maybeRequestFallback();
            return;
          }
          text = utf8.decode(clear);
        }
        // Incoming `e2e_fallback`: the PEER could not decrypt us. Mark for
        // plaintext outbound so both sides stop encrypting (the asymmetry
        // where one encrypts and the other cannot read it WAS the storm).
        if (text.startsWith('{"type":"e2e_fallback"}') ||
            text.startsWith('{"t "')) {
          final inner = jsonDecode(text);
          if (inner is Map && inner['type'] == 'e2e_fallback') {
            signaling.setPeerPlaintext(peerId);
            return;
          }
        }
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
          if (clear == null) {
            _maybeRequestFallback();
            if (bytes.isNotEmpty && bytes[0] == 0x50) {
              cb(RTCDataChannelMessage.fromBinary(bytes));
            }
            return;
          }
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

  /// Send a plaintext `e2e_fallback` request to the peer, at most once per
  /// session. Called when [SignalingService] has just reported this peer
  /// entered fallback; harmless to repeat (idempotent on the far side) but a
  /// guard avoids a request per in-flight chunk.
  void _maybeRequestFallback() {
    if (_fallbackRequested) return;
    if (!signaling.isPlaintextPeer(peerId)) return;
    _fallbackRequested = true;
    signaling.sendRelayPlaintext(peerId, {
      't': 'text',
      'd': '{"type":"e2e_fallback"}',
    });
  }
}
