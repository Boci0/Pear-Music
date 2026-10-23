import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/identity_service.dart';
import '../services/stream_cache_manager.dart';
import '../services/update_service.dart';
import '../theme/glass.dart';
import '../theme/pear_style.dart';
import '../widgets/pear_switch_tile.dart';
import '../widgets/about_dialog.dart';
import '../widgets/audio_engine_card.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/visualizer_permission.dart';
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
      appBar: const PearAppBar(label: 'Settings'),
      body: _SettingsBody(
        children: [
          _sectionTitle(context, 'Audio & Playback'),
          Card(
            clipBehavior: Clip.antiAlias,
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
                PearSwitchTile(
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
                ListenableBuilder(
                  listenable: identity,
                  builder: (context, _) {
                    final seconds = identity.crossfadeSeconds;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.swap_horiz_rounded),
                          title: const Text('Crossfade'),
                          subtitle: Text(
                            seconds == 0
                                ? 'Off: each song plays to its end'
                                : 'Songs blend into each other over $seconds s',
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              inactiveTrackColor:
                                  Colors.white.withValues(alpha: 0.14),
                              activeTickMarkColor:
                                  Colors.white.withValues(alpha: 0.35),
                              inactiveTickMarkColor:
                                  Colors.white.withValues(alpha: 0.25),
                            ),
                            child: Slider(
                            value: seconds.toDouble(),
                            max: IdentityService.maxCrossfadeSeconds.toDouble(),
                            divisions: IdentityService.maxCrossfadeSeconds,
                            label: seconds == 0 ? 'Off' : '$seconds s',
                            onChanged: (val) {
                              if (val.round() == seconds) return;
                              TactileFeedback.selection();
                              unawaited(identity.setCrossfadeSeconds(val.round()));
                              unawaited(controller.player.setCrossfadeSeconds(val.round()));
                            },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const Divider(height: 1),
                PearSwitchTile(
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
                PearSwitchTile(
                  secondary: const Icon(Icons.casino_rounded),
                  title: const Text('Auto-Reroll Seed'),
                  subtitle: const Text('Reroll recommendation seed on track change'),
                  value: controller.player.autoRerollSeed,
                  onChanged: (val) {
                    TactileFeedback.selection();
                    controller.player.setAutoRerollSeed(val);
                  },
                ),
                const Divider(height: 1),
                PearSwitchTile(
                  secondary: const Icon(Icons.bolt_rounded),
                  title: const Text('Fast audio engine'),
                  subtitle: const Text(
                    'Starts songs sooner, with yt-dlp as the fallback',
                  ),
                  value: identity.fastEngine,
                  onChanged: (val) async {
                    TactileFeedback.selection();
                    await identity.setFastEngine(val);
                  },
                ),
                const Divider(height: 1),
                PearSwitchTile(
                  secondary: const Icon(Icons.safety_check_rounded),
                  title: const Text('Backup audio engine'),
                  subtitle: const Text(
                    'If yt-dlp cannot fetch a song, try a built-in engine before giving up',
                  ),
                  value: identity.backupEngine,
                  onChanged: (val) async {
                    TactileFeedback.selection();
                    await identity.setBackupEngine(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Appearance'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListenableBuilder(
              listenable: identity,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Style'),
                    subtitle: Text(switch (identity.style) {
                      PearStyle.glass =>
                        'Translucent dark panels tinted by the song',
                      PearStyle.frosted =>
                        'Lighter, more colourful glass with a stronger edge',
                      PearStyle.solid =>
                        'Flat dark surfaces with no blur, easiest on the battery',
                      PearStyle.graphite =>
                        'Graphite panels, cut corners and thin lines',
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: SegmentedButton<PearStyle>(
                      expandedInsets: EdgeInsets.zero,
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        padding: WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 4),
                        ),
                      ),
                      segments: [
                        for (final style in PearStyle.values)
                          ButtonSegment(value: style, label: Text(style.label)),
                      ],
                      selected: {identity.style},
                      onSelectionChanged: (picked) async {
                        TactileFeedback.selection();
                        await identity.setStyle(picked.first);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Performance'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                PearSwitchTile(
                  secondary: const Icon(Icons.graphic_eq_rounded),
                  title: const Text('Visualizer'),
                  subtitle: Text(
                    !kIsWeb && Platform.isAndroid
                        ? 'A wave that moves with the music. Needs audio access'
                        : 'A wave that moves with the music',
                  ),
                  value: identity.synthesizerBar,
                  onChanged: (val) async {
                    TactileFeedback.selection();
                    // Explains the audio access before asking. Declining
                    // leaves the switch off.
                    if (val && !await VisualizerPermission.request(context)) {
                      return;
                    }
                    await controller.updateSynthesizerBar(val);
                  },
                ),
                const Divider(height: 1),
                PearSwitchTile(
                  secondary: const Icon(Icons.view_headline_rounded),
                  title: const Text('Wave on the mini player'),
                  subtitle: const Text('Uses more battery'),
                  value: identity.miniVisualizer,
                  // The wave comes from the visualizer, so it needs it on.
                  onChanged: identity.synthesizerBar
                      ? (val) async {
                          TactileFeedback.selection();
                          await controller.updateMiniVisualizer(val);
                        }
                      : null,
                ),
                const Divider(height: 1),
                // Same shape as Crossfade: the text, then the control under it,
                // so the long explanation keeps the row's full width. The
                // choices are the app's borderless segmented buttons.
                ListenableBuilder(
                  listenable: identity,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                        leading: Icon(Icons.high_quality_rounded),
                        title: Text('Video quality'),
                        subtitle: Text(
                          'Auto uses 360p on mobile data and 720p otherwise. A '
                          'moving 720p music video is about 30 MB a minute and '
                          '1080p about twice that.',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: SegmentedButton<int>(
                          // Fill the row; left alone it keeps its natural
                          // width and sits off-centre in the card.
                          expandedInsets: EdgeInsets.zero,
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 4),
                            ),
                          ),
                          segments: const [
                            ButtonSegment(value: 0, label: Text('Auto')),
                            ButtonSegment(value: 360, label: Text('360p')),
                            ButtonSegment(value: 480, label: Text('480p')),
                            ButtonSegment(value: 720, label: Text('720p')),
                            ButtonSegment(value: 1080, label: Text('1080p')),
                          ],
                          selected: {identity.videoQuality},
                          onSelectionChanged: (picked) async {
                            TactileFeedback.selection();
                            await identity.setVideoQuality(picked.first);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                PearSwitchTile(
                  secondary: const Icon(Icons.battery_saver_rounded),
                  title: const Text('Reduced Effects'),
                  subtitle: const Text(
                      'Static glow, no seek ripple, no glass blur and no button bounce. With the visualizer off the player scene stops repainting, which cuts battery use.'),
                  value: identity.reducedEffects,
                  onChanged: (val) async {
                    TactileFeedback.selection();
                    await controller.updateReducedEffects(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionTitle(context, 'Discovery & Search'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                PearSwitchTile(
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
          if (!kIsWeb && Platform.isWindows) ...[
            const SizedBox(height: 18),
            _sectionTitle(context, 'Audio engine'),
            const AudioEngineCard(),
          ],
          const SizedBox(height: 18),
          _sectionTitle(context, 'About & Updates'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('Check for updates'),
                  subtitle: Text('Version ${UpdateService.displayVersion}'),
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
                              shape: PearStyles.spec.angular ? BoxShape.rectangle : BoxShape.circle,
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

  /// Section order, for the numbers angular styles put before each title.
  static const _sections = [
    'Audio & Playback',
    'Appearance',
    'Performance',
    'Discovery & Search',
    'Storage & Cache',
    'Audio engine',
    'About & Updates',
  ];

  Widget _sectionTitle(BuildContext context, String title) {
    if (PearStyles.spec.angular) return _numberedTitle(context, title);
    return _plainTitle(context, title);
  }

  /// Angular styles: "01 // AUDIO & PLAYBACK", the number in the accent and
  /// the name in spaced grey capitals, ending in a hairline.
  Widget _numberedTitle(BuildContext context, String title) {
    // Numbered among the sections this platform shows.
    final visible = [
      for (final s in _sections)
        if (s != 'Audio engine' || (!kIsWeb && Platform.isWindows)) s,
    ];
    final number = (visible.indexOf(title) + 1).toString().padLeft(2, '0');
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10, top: 8),
      child: Row(
        children: [
          Text(
            number,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '  //  ',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.6,
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              color: Colors.white.withValues(alpha: PearGlassTokens.edge),
            ),
          ),
        ],
      ),
    );
  }

  Widget _plainTitle(BuildContext context, String title) => Padding(
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

/// Keeps the settings cards to a readable column: on wide windows the rows
/// stop stretching across the whole content width, and the leftover space
/// falls evenly on both sides instead of reading as a dead strip.
class _SettingsBody extends StatelessWidget {
  final List<Widget> children;

  const _SettingsBody({required this.children});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: children,
        ),
      ),
    );
  }
}
