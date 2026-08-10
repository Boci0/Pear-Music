import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';

/// Settings: device name and signaling server URL.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _serverController;
  late final FocusNode _serverUrlFocus;
  Timer? _serverUrlDebounce;

  @override
  void initState() {
    super.initState();
    final identity = context.read<AppController>().identity;
    _nameController = TextEditingController(text: identity.deviceName);
    _serverController = TextEditingController(text: identity.serverUrl);
    _serverUrlFocus = FocusNode()..addListener(_onServerUrlFocus);
    // Auto-apply the server URL as the user edits it (debounced), so no one
    // gets stuck because they forgot to tap "Connect".
    _serverController.addListener(_onServerUrlChanged);
  }

  /// Select all when the URL field is focused, so typing *replaces* the old
  /// value instead of mixing into "ws://localhost:8080".
  void _onServerUrlFocus() {
    if (_serverUrlFocus.hasFocus) {
      _serverController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _serverController.text.length,
      );
    }
  }

  void _onServerUrlChanged() {
    _serverUrlDebounce?.cancel();
    _serverUrlDebounce = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      final text = _serverController.text.trim();
      final current = context.read<AppController>().identity.serverUrl;
      if (text.isNotEmpty && text != current) {
        context.read<AppController>().updateServerUrl(text);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server URL saved & reconnecting…')),
        );
      }
    });
  }

  @override
  void dispose() {
    _serverUrlDebounce?.cancel();
    _nameController.dispose();
    _serverController.dispose();
    _serverUrlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final identity = controller.identity;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _sectionTitle(context, 'This device'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Device name',
                      helperText: 'Shown to other paired devices',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        controller.updateDeviceName(_nameController.text);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Name updated')),
                        );
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Save name'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    'Device ID: ${identity.deviceId}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, 'Connection'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _HostingStatus(),
                  const Divider(height: 8),
                  // Manual server URL is an advanced setting now — discovery
                  // finds the host automatically in normal use.
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Advanced: server settings'),
                    childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                    children: [
                      TextField(
                        controller: _serverController,
                        focusNode: _serverUrlFocus,
                        decoration: const InputDecoration(
                          labelText: 'Signaling server URL',
                          helperText:
                              'WebSocket URL (ws:// or wss://). All devices '
                              'must point to the same server.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            controller.updateServerUrl(_serverController.text);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Reconnecting to server…')),
                            );
                          },
                          icon: const Icon(Icons.cloud_sync),
                          label: const Text('Connect'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, 'Download from links'),
          Card(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Text(
                'Links are downloaded with yt-dlp: bundled on the phone, '
                'installed on the PC (winget install yt-dlp.yt-dlp). Works for '
                'YouTube and Spotify links.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, 'About Pear Music'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Pear Music syncs music files between your paired devices over '
                'your own server, and plays them locally on every device.\n\n'
                '• Adding a song syncs it to every online paired device.\n'
                '• Songs you add yourself stay in your library.\n'
                '• Unpairing a device deletes the songs it received from you.\n'
                '• You can use Pear Music without pairing at all. It works '
                'as a local music player too.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.5,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
}

/// Shows whether THIS device is hosting the embedded signaling server, and —
/// when it is — the address other devices should use to connect to it.
class _HostingStatus extends StatelessWidget {
  const _HostingStatus();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final hosting = controller.isHostingServer;
    final port = controller.server.boundPort;
    final ip = controller.serverLanIp;
    final scheme = Theme.of(context).colorScheme;
    if (hosting) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.dns, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                'This device is hosting the server.\n'
                'Point other devices at: '
                'ws://${ip ?? '<this-device-ip>'}:$port',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off,
              size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Not hosting on this device (port $port busy) — using the '
              'server URL below.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

