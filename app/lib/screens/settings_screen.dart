import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/stream_cache_manager.dart';
import '../services/update_service.dart';
import '../widgets/about_dialog.dart';

/// Clean, decluttered settings screen organized by functional sections.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/pear_logo.png',
              width: 28,
              height: 28,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 8),
            const Text('Settings'),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
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
                SwitchListTile(
                  secondary: const Icon(Icons.autorenew_rounded),
                  title: const Text('Auto-Reroll Seed'),
                  subtitle: const Text('Continuously fetch and cache next track based on playing song'),
                  value: controller.player.autoRerollSeed,
                  onChanged: (val) {
                    controller.player.setAutoRerollSeed(val);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_play_rounded),
                  title: const Text('Autoplay'),
                  subtitle: const Text('Continue playing recommendations when queue ends'),
                  value: controller.player.autoplay,
                  onChanged: (val) {
                    controller.player.setAutoplay(val);
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
