import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/stream_cache_manager.dart';
import '../services/update_service.dart';
import '../widgets/about_dialog.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/tactile_button.dart';

/// Clean, decluttered settings screen organized by functional sections.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _cacheSizeLabel([int? bytesOverride]) {
    final bytes = bytesOverride ?? StreamCacheManager.getCacheStats().totalBytes;
    if (bytes <= 0) return '0.0 MB used';
    final mb = bytes / (1024 * 1024);
    if (mb < 1000) {
      return '${mb.toStringAsFixed(1)} MB used';
    }
    return '${(mb / 1024).toStringAsFixed(2)} GB used';
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
          TactileBounce(
            onTap: () => Navigator.pop(ctx, false),
            child: IgnorePointer(
              child: TextButton(
                onPressed: () {},
                child: const Text('Cancel'),
              ),
            ),
          ),
          TactileBounce(
            onTap: () => Navigator.pop(ctx, true),
            child: IgnorePointer(
              child: FilledButton(
                onPressed: () {},
                child: const Text('Clear cache'),
              ),
            ),
          ),
        ],
      ),
    );

    if (ok == true) {
      await StreamCacheManager.clearCache();
      if (mounted) {
        setState(() {});
      }
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
        automaticallyImplyLeading: false,
        titleSpacing: 16,
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
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Master Volume',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 10),
                      const PlayerVolumeSlider(),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.equalizer_rounded),
                  title: const Text('Loudness Normalization'),
                  subtitle: const Text('Equalize volume across tracks'),
                  value: identity.loudnessNormalization,
                  onChanged: (val) async {
                    TactileFeedback.selection();
                    await identity.setLoudnessNormalization(val);
                    await controller.player.setLoudnessNormalization(val);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_play_rounded),
                  title: const Text('Endless Play'),
                  subtitle: const Text('Keep playing recommendations when queue ends'),
                  value: controller.player.autoplay,
                  onChanged: (val) {
                    TactileFeedback.selection();
                    controller.player.setAutoplay(val);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.casino_rounded),
                  title: const Text('Auto-Reroll Seed'),
                  subtitle: const Text('Reroll recommendation seed on track change'),
                  value: controller.player.autoRerollSeed,
                  onChanged: (val) {
                    TactileFeedback.selection();
                    controller.player.setAutoRerollSeed(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Performance'),
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: SwitchListTile(
              secondary: const Icon(Icons.battery_saver_rounded),
              title: const Text('Reduced Effects'),
              subtitle: const Text(
                  'Static glow and no seek ripple. With the visualizer off the player scene stops repainting, which cuts battery use.'),
              value: identity.reducedEffects,
              onChanged: (val) async {
                TactileFeedback.selection();
                await controller.updateReducedEffects(val);
              },
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Discovery & Search'),
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.travel_explore_rounded),
                  title: const Text('Expanded Search Scope'),
                  subtitle: const Text('Include music videos, covers, and community uploads alongside official audio'),
                  value: identity.extendedSearch,
                  onChanged: (val) async {
                    TactileFeedback.selection();
                    await identity.setExtendedSearch(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Storage & Cache'),
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: StreamCacheManager.cacheBytesNotifier,
                  builder: (context, bytes, _) => ListTile(
                    leading: const Icon(Icons.cleaning_services_rounded),
                    title: const Text('Clear streaming cache'),
                    subtitle: Text(
                      '${_cacheSizeLabel(bytes)}; tap to free temporary streams',
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () {
                      TactileFeedback.click();
                      _confirmClearCache(context);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'About & Updates'),
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
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
                  onTap: () {
                    TactileFeedback.click();
                    UpdateService.checkForUpdates(context, quiet: false);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About Pear Music'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () {
                    TactileFeedback.click();
                    showPearMusicAboutDialog(context);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 140),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(left: 6, bottom: 8, top: 4),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
      ),
    ),
  );
}
