import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/pairing_link.dart';

/// Full-screen QR scanner used by the Join pairing flow.
///
/// Points the camera at the QR shown on the other device and returns the RAW
/// scanned payload via [Navigator.pop] — either a bare 6-character code or the
/// `pearmusic://pair/<code>[?server=…]` deep link the host QR encodes. The
/// caller ([PairScreen]) parses it with [PairingLink] to get the code and the
/// host's server address, so it can switch servers automatically if needed.
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
      // Accepts a raw code or a `pearmusic://pair/…` deep link; returns the
      // raw payload so the caller can also read the server hint from it.
      if (PairingLink.parse(raw) != null) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
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
