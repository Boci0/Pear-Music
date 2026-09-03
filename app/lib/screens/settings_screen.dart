import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/stream_cache_manager.dart';
import '../services/update_service.dart';
import '../widgets/about_dialog.dart';

/// Clean, decluttered settings screen organized by functional sections.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _showEditDeviceNameDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final textController = TextEditingController(
      text: controller.identity.deviceName,
    );
    final formKey = GlobalKey<FormState>();

    final updatedName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change device name'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Device name',
              hintText: 'e.g. My Phone, Laptop',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Name cannot be empty';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, textController.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (updatedName != null && updatedName.isNotEmpty) {
      await controller.updateDeviceName(updatedName);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Device name updated')));
      }
    }
  }

  Future<void> _showEditServerUrlDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final textController = TextEditingController(
      text: controller.identity.serverUrl,
    );
    final formKey = GlobalKey<FormState>();

    final updatedUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Signaling server URL'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'All paired devices must point to the same signaling server URL.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: textController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'WebSocket URL',
                  hintText: 'ws://192.168.1.100:8080',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) return 'URL cannot be empty';
                  if (!trimmed.startsWith('ws://') &&
                      !trimmed.startsWith('wss://')) {
                    return 'URL must start with ws:// or wss://';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, textController.text.trim());
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );

    if (updatedUrl != null && updatedUrl.isNotEmpty) {
      await controller.updateServerUrl(updatedUrl);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server URL updated; reconnecting...')),
        );
      }
    }
  }

  Future<void> _confirmClearCache(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear streaming cache?'),
        content: const Text(
          'This removes all temporary radio and online streaming audio cache files from your device. Local songs in your library will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await StreamCacheManager.clearCache();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Streaming cache cleared')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final identity = controller.identity;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _sectionTitle(context, 'This device'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.devices_rounded),
                  title: Text(identity.deviceName),
                  subtitle: const Text('Tap to change device name'),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () => _showEditDeviceNameDialog(context, controller),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Device ID'),
                  subtitle: Text(
                    identity.deviceId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.copy_rounded, size: 20),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: identity.deviceId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Device ID copied to clipboard'),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, 'Audio & Playback'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.equalizer_rounded),
                  title: const Text('Loudness Normalization'),
                  subtitle: const Text('Equalize volume across tracks'),
                  value: identity.loudnessNormalization,
                  onChanged: (val) async {
                    await identity.setLoudnessNormalization(val);
                    await controller.player.setLoudnessNormalization(val);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.graphic_eq_rounded),
                  title: const Text('Synthesizer Seek Bar'),
                  subtitle: const Text('Beat-reactive spectrum bar chart on progress bar'),
                  value: identity.synthesizerBar,
                  onChanged: (val) async {
                    await controller.updateSynthesizerBar(val);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_rounded),
                  title: const Text('Clear streaming cache'),
                  subtitle: const Text(
                    'Free disk space used by temporary streams',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _confirmClearCache(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, 'Network & Sync'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    controller.isHostingServer
                        ? Icons.dns_rounded
                        : Icons.cloud_outlined,
                    color: controller.isHostingServer
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  title: const Text('Hosting Status'),
                  subtitle: Text(
                    controller.isHostingServer
                        ? 'Hosting signaling server on port ${controller.server.boundPort}'
                        : 'Connected to signaling host',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cloud_sync_rounded),
                  title: const Text('Signaling Server'),
                  subtitle: Text(
                    identity.serverUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () => _showEditServerUrlDialog(context, controller),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, 'About & Updates'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('Check for updates'),
                  subtitle: Text('Version ${UpdateService.currentVersion}'),
                  trailing: ValueListenableBuilder<bool>(
                    valueListenable: UpdateService.updateAvailable,
                    builder: (context, available, child) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (available) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        const Icon(Icons.chevron_right, size: 20),
                      ],
                    ),
                  ),
                  onTap: () =>
                      UpdateService.checkForUpdates(context, quiet: false),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About Pear Music'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => showPearMusicAboutDialog(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
