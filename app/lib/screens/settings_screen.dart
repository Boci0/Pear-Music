import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/artwork_service.dart';
import '../services/identity_service.dart';
import '../services/lyrics_service.dart';
import '../services/stream_cache_manager.dart';
import '../services/update_service.dart';
import '../widgets/about_dialog.dart';
import '../widgets/player/player_controls.dart';

/// Clean, decluttered settings screen organized by functional sections.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _showQualityDialog(BuildContext context, IdentityService identity) async {
    final selected = await showDialog<StreamingQuality>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Streaming Audio Quality'),
        children: StreamingQuality.values.map((q) {
          final isSelected = identity.streamingQuality == q;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, q),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          q.label,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        Text(
                          q.subtitle,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );

    if (selected != null && selected != identity.streamingQuality) {
      await identity.setStreamingQuality(selected);
      StreamCacheManager.setStreamingQuality(selected);
      if (context.mounted) {
        await context.read<AppController>().player.onStreamingQualityChanged(reloadCurrent: true);
      }
      if (mounted) setState(() {});
    }
  }
  String _cacheSizeLabel() {
    final bytes = StreamCacheManager.getCacheStats().totalBytes;
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
                    controller.player.setAutoRerollSeed(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Data & Internet'),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.high_quality_rounded),
                  title: const Text('Streaming Audio Quality'),
                  subtitle: Text(
                    '${identity.streamingQuality.label} (${identity.streamingQuality.subtitle})',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _showQualityDialog(context, identity),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.lyrics_rounded),
                  title: const Text('Fetch Online Lyrics'),
                  subtitle: const Text('Download synchronized lyrics from LRCLIB'),
                  value: identity.onlineLyrics,
                  onChanged: (val) async {
                    await identity.setOnlineLyrics(val);
                    LyricsService.onlineLyricsEnabled = val;
                    setState(() {});
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.downloading_rounded),
                  title: const Text('Preload Next Track'),
                  subtitle: const Text('Buffer upcoming track in background for gapless play'),
                  value: identity.preloadUpcoming,
                  onChanged: (val) async {
                    await identity.setPreloadUpcoming(val);
                    if (!val) {
                      StreamCacheManager.cancelPreload();
                    } else {
                      controller.player.onStreamingQualityChanged();
                    }
                    setState(() {});
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.image_outlined),
                  title: const Text('Online Album Artwork'),
                  subtitle: const Text('Load high-resolution artwork and thumbnails over internet'),
                  value: identity.onlineArtwork,
                  onChanged: (val) async {
                    await identity.setOnlineArtwork(val);
                    ArtworkService.onlineArtworkEnabled = val;
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Storage & Cache'),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cleaning_services_rounded),
                  title: const Text('Clear streaming cache'),
                  subtitle: Text(
                    '${_cacheSizeLabel()}; tap to free temporary streams',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _confirmClearCache(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'About & Updates'),
          Card(
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
    padding: const EdgeInsets.only(left: 6, bottom: 8, top: 4),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
      ),
    ),
  );
}
