import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen QR scanner used by the Join pairing flow.
///
/// Points the camera at the QR shown on the other device and returns the
/// pairing code via [Navigator.pop]. It accepts either a raw 6-character code
/// or the `pearmusic://pair/<code>` deep link that the host QR encodes, so the
/// host and join flows stay symmetric.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    facing: CameraFacing.back,
  );

  /// Guards against popping twice when the same code is detected repeatedly.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final code = _extractPairingCode(raw);
      if (code != null) {
        _handled = true;
        Navigator.of(context).pop(code);
        return;
      }
    }
  }

  /// Pulls the 6-char pairing code out of a raw code or a `pearmusic://pair/…`
  /// deep link. Returns null if the value isn't a valid pairing code.
  String? _extractPairingCode(String raw) {
    final trimmed = raw.trim();
    const prefix = 'pearmusic://pair/';
    if (trimmed.startsWith(prefix)) {
      final code = trimmed.substring(prefix.length).trim().toUpperCase();
      return code.length == 6 ? code : null;
    }
    final upper = trimmed.toUpperCase();
    return upper.length == 6 ? upper : null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR code')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.no_photography,
                          size: 48, color: scheme.error),
                      const SizedBox(height: 12),
                      Text(
                        'Camera unavailable. Grant camera permission to scan '
                        'pairing codes.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          // Scan target overlay: a corner-bracket frame + hint.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.9),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Text(
              'Point the camera at the QR code on the other device',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
