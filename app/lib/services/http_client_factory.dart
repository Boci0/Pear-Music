import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'debug_log.dart';

/// Shared HTTP client factory enforcing IPv4-first sockets, bounded DNS/connect
/// timeouts, and optional cancellation hooks across all `dart:io` callers.
///
/// On networks with a broken IPv6 route, Dart's stock [HttpClient] stalls on
/// the first address it tries. Routing every caller through one factory keeps
/// connection behaviour and timeout bounds consistent.
class PearHttpClientFactory {
  PearHttpClientFactory._();

  static const Duration defaultDnsTimeout = Duration(seconds: 4);
  static const Duration defaultConnectTimeout = Duration(seconds: 15);

  /// Creates a configured [HttpClient] with IPv4-first socket connection,
  /// bounded DNS resolution timeout, and optional [cancelSignal].
  static HttpClient create({
    Duration connectionTimeout = defaultConnectTimeout,
    Duration dnsTimeout = defaultDnsTimeout,
    Duration? idleTimeout,
    int? maxConnectionsPerHost,
    bool autoUncompress = true,
    Future<void>? cancelSignal,
  }) {
    final client = HttpClient()
      ..connectionTimeout = connectionTimeout
      ..autoUncompress = autoUncompress;
    if (idleTimeout != null) client.idleTimeout = idleTimeout;
    if (maxConnectionsPerHost != null) {
      client.maxConnectionsPerHost = maxConnectionsPerHost;
    }

    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? uri.port;
      final secure = proxyHost == null && uri.scheme == 'https';

      Future<ConnectionTask<Socket>> connect(Object address) => secure
          ? SecureSocket.startConnect(address, port, supportedProtocols: null)
          : Socket.startConnect(address, port);

      // Skip DNS when the host is already a numeric IP literal (e.g. 127.0.0.1 or ::1).
      final literal = InternetAddress.tryParse(host);
      if (literal != null) {
        return connect(literal);
      }

      try {
        final v4 = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(dnsTimeout);
        if (v4.isNotEmpty) {
          return await connect(v4.first);
        }
      } catch (_) {}
      return connect(host);
    };

    if (cancelSignal != null) {
      unawaited(
        cancelSignal.whenComplete(() {
          try {
            client.close(force: true);
          } catch (_) {}
        }),
      );
    }

    return client;
  }

  /// Creates an `http.Client` backed by [create].
  static http.Client createClient({
    Duration connectionTimeout = defaultConnectTimeout,
    Duration dnsTimeout = defaultDnsTimeout,
    Duration? idleTimeout,
    int? maxConnectionsPerHost,
    Future<void>? cancelSignal,
  }) => IOClient(
    create(
      connectionTimeout: connectionTimeout,
      dnsTimeout: dnsTimeout,
      idleTimeout: idleTimeout,
      maxConnectionsPerHost: maxConnectionsPerHost,
      cancelSignal: cancelSignal,
    ),
  );
}

/// Outcome of a [ResumableDownloader.downloadToFile] call.
class ResumableDownloadResult {
  const ResumableDownloadResult({
    required this.success,
    this.error,
    this.cancelled = false,
    this.checksumMismatch = false,
    this.resumedBytes = 0,
    this.attempts = 0,
  });

  final bool success;
  final String? error;
  final bool cancelled;
  final bool checksumMismatch;
  final int resumedBytes;
  final int attempts;
}

/// Downloads a verified binary across one or more mirror URLs using `.part`
/// temp files, HTTP `Range` resumption, bounded stall timeouts, and atomic
/// rename only after full-file SHA-256 verification.
class ResumableDownloader {
  ResumableDownloader._();

  static final RegExp _contentRangeRegex = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    caseSensitive: false,
  );

  /// Computes lowercase SHA-256 hex digest of [file] on a worker isolate.
  static Future<String> computeFileSha256(File file) {
    final path = file.path;
    return Isolate.run(() async {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString().toLowerCase();
    });
  }

  /// Downloads from [urls] into `${destFile.path}.part`, verifies SHA-256
  /// against [expectedSha256], and atomically promotes to [destFile].
  static Future<ResumableDownloadResult> downloadToFile({
    required List<String> urls,
    required File destFile,
    required String expectedSha256,
    Map<String, String> headers = const {},
    Duration connectionTimeout = const Duration(seconds: 12),
    Duration responseTimeout = const Duration(seconds: 15),
    Duration stallTimeout = const Duration(seconds: 25),
    int minBytes = 1,
    void Function(int received, int total)? onProgress,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
  }) async {
    final expected = expectedSha256.trim().toLowerCase();
    if (expected.isEmpty || urls.isEmpty) {
      return const ResumableDownloadResult(
        success: false,
        error: 'Download failed.',
      );
    }

    final partFile = File('${destFile.path}.part');
    final metaFile = File('${destFile.path}.part.meta');

    await _preparePartForIdentity(partFile, metaFile, expected);

    var lastError = 'Download failed.';
    var checksumFailed = false;
    var maxResumedBytes = 0;
    var attempts = 0;

    for (final url in urls) {
      if (shouldCancel?.call() ?? false) {
        return ResumableDownloadResult(
          success: false,
          error: 'Update download cancelled.',
          cancelled: true,
          resumedBytes: maxResumedBytes,
          attempts: attempts,
        );
      }

      // Allow one clean restart from byte 0 if a server rejects Range (416)
      // or returns an unexpected Content-Range start.
      for (var pass = 0; pass < 2; pass++) {
        attempts++;
        if (shouldCancel?.call() ?? false) {
          return ResumableDownloadResult(
            success: false,
            error: 'Update download cancelled.',
            cancelled: true,
            resumedBytes: maxResumedBytes,
            attempts: attempts,
          );
        }

        final client = PearHttpClientFactory.create(
          connectionTimeout: connectionTimeout,
          autoUncompress: false,
          cancelSignal: cancelSignal,
        );

        try {
          var existingBytes = 0;
          if (await partFile.exists() && await metaFile.exists()) {
            final meta = await _readMeta(metaFile);
            if (meta == expected) {
              existingBytes = await partFile.length();
            } else {
              await _deleteQuietly(partFile);
              await _deleteQuietly(metaFile);
            }
          } else if (await partFile.exists()) {
            // Orphaned .part without matching .part.meta cannot be trusted.
            await _deleteQuietly(partFile);
          }

          final request = await client
              .getUrl(Uri.parse(url))
              .timeout(connectionTimeout);
          headers.forEach(request.headers.set);
          if (existingBytes > 0) {
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
          }

          if (shouldCancel?.call() ?? false) {
            request.abort();
            return ResumableDownloadResult(
              success: false,
              error: 'Update download cancelled.',
              cancelled: true,
              resumedBytes: maxResumedBytes,
              attempts: attempts,
            );
          }

          final response = await request.close().timeout(responseTimeout);

          if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
            await response.drain<void>();
            if (existingBytes > 0 && await partFile.exists()) {
              final existingHash = await computeFileSha256(partFile);
              if (existingHash == expected &&
                  await partFile.length() >= minBytes) {
                await _promotePartFile(partFile, metaFile, destFile);
                return ResumableDownloadResult(
                  success: true,
                  resumedBytes: existingBytes,
                  attempts: attempts,
                );
              }
            }
            await _deleteQuietly(partFile);
            await _deleteQuietly(metaFile);
            if (pass == 0) continue;
            lastError = 'Download failed (HTTP ${response.statusCode})';
            break;
          }

          if (response.statusCode != HttpStatus.ok &&
              response.statusCode != HttpStatus.partialContent) {
            await response.drain<void>();
            lastError = 'Download failed (HTTP ${response.statusCode})';
            break;
          }

          var appendMode = false;
          var receivedBytes = 0;
          var totalBytes =
              response.contentLength > 0 ? response.contentLength : 0;

          if (response.statusCode == HttpStatus.partialContent &&
              existingBytes > 0) {
            final rangeHeader =
                response.headers.value(HttpHeaders.contentRangeHeader)?.trim();
            final rangeMatch = rangeHeader == null
                ? null
                : _contentRangeRegex.firstMatch(rangeHeader);
            final start = rangeMatch == null
                ? null
                : int.tryParse(rangeMatch.group(1)!);
            if (start != existingBytes) {
              await response.drain<void>();
              await _deleteQuietly(partFile);
              await _deleteQuietly(metaFile);
              if (pass == 0) continue;
              lastError = 'Update download failed. Please try again.';
              break;
            }
            appendMode = true;
            receivedBytes = existingBytes;
            if (existingBytes > maxResumedBytes) {
              maxResumedBytes = existingBytes;
            }
            final totalGroup = rangeMatch?.group(3);
            if (totalGroup != null && totalGroup != '*') {
              totalBytes = int.tryParse(totalGroup) ?? totalBytes;
            } else if (response.contentLength > 0) {
              totalBytes = existingBytes + response.contentLength;
            }
            onProgress?.call(receivedBytes, totalBytes);
          } else {
            // Server returned 200 OK (no Range support): start fresh into .part.
            await _deleteQuietly(partFile);
          }

          await metaFile.writeAsString(expected, flush: true);
          final sink = partFile.openWrite(
            mode: appendMode ? FileMode.append : FileMode.write,
          );
          try {
            await for (final chunk in response.timeout(stallTimeout)) {
              if (shouldCancel?.call() ?? false) {
                throw StateError('cancelled');
              }
              sink.add(chunk);
              receivedBytes += chunk.length;
              onProgress?.call(receivedBytes, totalBytes);
            }
            await sink.flush();
            await sink.close();
          } catch (e) {
            try {
              await sink.flush();
            } catch (_) {}
            try {
              await sink.close();
            } catch (_) {}
            if (shouldCancel?.call() ?? false) {
              return ResumableDownloadResult(
                success: false,
                error: 'Update download cancelled.',
                cancelled: true,
                resumedBytes: maxResumedBytes,
                attempts: attempts,
              );
            }
            lastError = 'Update download stalled or failed. Please try again.';
            break;
          }

          final partLen = await partFile.length();
          if (totalBytes > 0 && partLen < totalBytes) {
            DebugLog.write(
              '[download] stream ended early from $url ($partLen / $totalBytes bytes); keeping .part for resume',
            );
            lastError = 'Update download stalled or failed. Please try again.';
            break;
          }

          final actual = await computeFileSha256(partFile);
          if (partLen >= minBytes && actual == expected) {
            await _promotePartFile(partFile, metaFile, destFile);
            return ResumableDownloadResult(
              success: true,
              resumedBytes: maxResumedBytes,
              attempts: attempts,
            );
          }

          DebugLog.write(
            '[download] verification failed for $url: '
            'len=$partLen (min=$minBytes), sha=$actual != $expected',
          );
          await _deleteQuietly(partFile);
          await _deleteQuietly(metaFile);
          checksumFailed = true;
          lastError =
              'Checksum mismatch: the downloaded update failed verification '
              'and was deleted.';
          break;
        } catch (e) {
          DebugLog.write('[download] attempt from $url failed: $e');
          if (shouldCancel?.call() ?? false) {
            return ResumableDownloadResult(
              success: false,
              error: 'Update download cancelled.',
              cancelled: true,
              resumedBytes: maxResumedBytes,
              attempts: attempts,
            );
          }
          lastError = 'Update download failed. Please try again.';
          break;
        } finally {
          client.close(force: true);
        }
      }
    }

    return ResumableDownloadResult(
      success: false,
      error: lastError,
      checksumMismatch: checksumFailed,
      resumedBytes: maxResumedBytes,
      attempts: attempts,
    );
  }

  static Future<void> _preparePartForIdentity(
    File partFile,
    File metaFile,
    String expected,
  ) async {
    try {
      final meta = await _readMeta(metaFile);
      if (meta != null && meta != expected) {
        await _deleteQuietly(partFile);
        await _deleteQuietly(metaFile);
      } else if (meta == null && await partFile.exists()) {
        await _deleteQuietly(partFile);
      }
    } catch (_) {}
  }

  static Future<String?> _readMeta(File metaFile) async {
    try {
      if (!await metaFile.exists()) return null;
      return (await metaFile.readAsString()).trim().toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _promotePartFile(
    File partFile,
    File metaFile,
    File destFile,
  ) async {
    await _deleteQuietly(metaFile);
    if (await destFile.exists()) {
      await _deleteQuietly(destFile);
    }
    try {
      await partFile.rename(destFile.path);
    } catch (_) {
      // On Windows an open target or cross-volume move can block rename; copy
      // atomically then clean up .part.
      await partFile.copy(destFile.path);
      await _deleteQuietly(partFile);
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
