import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controllers/app_controller.dart';
import '../services/pairing_link.dart';
import 'qr_scan_screen.dart';

/// Two-way pairing:
///  - Host: generate a 6-character code (with QR) for the other device.
///  - Join: type the code shown on the other device.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  String _mode = 'host'; // 'host' | 'join'
  final _codeController = TextEditingController();
  int _initialPairedCount = 0;
  late final AppController _controller;

  /// True once we've decided to auto-pop. This screen is a ChangeNotifier
  /// listener, and `notifyListeners()` fires a LOT while the sync handshake /
  /// file transfers run right after pairing. Without a one-shot guard, every
  /// notification would schedule another `Navigator.pop()`, and the second pop
  /// pops the HomeShell underneath (the root route) → black screen on both
  /// devices.
  bool _autoPopping = false;

  @override
  void initState() {
    super.initState();
    _controller = context.read<AppController>();
    _initialPairedCount = _controller.pairedDevices.length;
    // Auto-pop when a new device pairs successfully.
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _codeController.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Never look up ancestors via `context` here: this callback can fire while
    // the route is mid-pop (deactivated), where `context.read` throws.
    // Use the controller captured in initState instead.
    if (_autoPopping || !mounted) return;
    if (_controller.pairedDevices.length <= _initialPairedCount) return;

    _autoPopping = true;
    // The pairing event can fire mid-frame / during a transition. Popping
    // right away would assert because the navigator is locked. Defer it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a device')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (controller.connectionStatus != 'connected') ...[
            _ConnectionBanner(
              status: controller.connectionStatus,
              onOpenSettings: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 16),
          ],
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'host',
                label: Text('Share my code'),
                icon: Icon(Icons.qr_code_2),
              ),
              ButtonSegment(
                value: 'join',
                label: Text('Enter a code'),
                icon: Icon(Icons.keyboard),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 24),
          if (_mode == 'host') _buildHost(controller) else _buildJoin(controller),
        ],
      ),
    );
  }

  Widget _buildHost(AppController controller) {
    if (controller.pendingPairingCode == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.pendingPairingCode == null) {
          controller.generatePairingCode();
        }
      });
    }
    final code = controller.pendingPairingCode ?? '';
    return Column(
      children: [
        Text('Show this code to the other device',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              QrImageView(
                data: PairingLink.encode(code),
                version: QrVersions.auto,
                size: 180,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    code,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          letterSpacing: 8,
                          fontWeight: FontWeight.bold,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy code',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Expires in 10 minutes · one-time use',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'The other device can scan this QR or enter the code, it '
                'will find this device automatically.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: controller.generatePairingCode,
          icon: const Icon(Icons.refresh),
          label: const Text('Generate a new code'),
        ),
      ],
    );
  }

  Widget _buildJoin(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter the 6-character code shown on the other device.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          maxLength: 6,
          style: const TextStyle(
            fontSize: 28,
            letterSpacing: 6,
            fontWeight: FontWeight.bold,
          ),
          decoration: InputDecoration(
            counterText: '',
            hintText: 'AB12CD',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Scan QR code',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => _scan(controller),
            ),
          ),
          onSubmitted: (_) => _join(controller),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _join(controller),
          icon: const Icon(Icons.link),
          label: const Text('Pair'),
        ),
      ],
    );
  }

  Future<void> _scan(AppController controller) async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (raw == null || !mounted) return;
    final link = PairingLink.parse(raw);
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That QR is not a valid pairing code')),
      );
      return;
    }
    // The QR only carries the code. If this device is on a different server
    // than the host, pairSmart auto-discovers the host and connects there.
    _codeController.text = link.code;
    await _join(controller);
  }

  Future<void> _join(AppController controller) async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the 6-character code')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pairing…')),
    );
    // Smart pairing: tries the current server, then discovers nearby hosts
    // and retries there (so typing the code works even when this device is
    // on a different server than the host).
    final error = await controller.pairSmart(code);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }
}

/// Shown when the device is not connected to the signaling server, so pairing
/// failures are obvious instead of silently doing nothing.
class _ConnectionBanner extends StatelessWidget {
  final String status;
  final VoidCallback onOpenSettings;

  const _ConnectionBanner({required this.status, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status == 'connecting'
                  ? 'Connecting to server…'
                  : 'Not connected to the server. Set the server URL in '
                      'Settings, then tap Connect.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: onOpenSettings,
            child: const Text('Settings'),
          ),
        ],
      ),
    );
  }
}
