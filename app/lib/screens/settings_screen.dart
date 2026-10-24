import '../widgets/pear_sheet.dart';
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/identity_service.dart';
import '../services/stream_cache_manager.dart';
import '../services/update_service.dart';
import '../theme/glass.dart';
import '../widgets/pear_switch_tile.dart';
import '../widgets/about_dialog.dart';
import '../widgets/audio_engine_card.dart';
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
    final bytes =
        bytesOverride ?? StreamCacheManager.getCacheStats().totalBytes;
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
      builder: (ctx) => PearAlertDialog(
        title: const Text('Clear streaming cache?'),
        content: const Text(
          'This removes all temporary radio and online streaming audio cache files from your device. Local songs in your library will not be deleted.',
        ),
        actions: [
          TactileBounce(
            onTap: () => Navigator.pop(ctx, false),
            child: IgnorePointer(
              child: TextButton(onPressed: () {}, child: const Text('Cancel')),
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

    // Each section's title and rows, shared by both layouts.
    final sections = <(String, List<Widget>)>[
      (
        'Audio & Playback',
        [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Master Volume',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
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
                        inactiveTrackColor: Colors.white.withValues(
                          alpha: 0.14,
                        ),
                        activeTickMarkColor: Colors.white.withValues(
                          alpha: 0.35,
                        ),
                        inactiveTickMarkColor: Colors.white.withValues(
                          alpha: 0.25,
                        ),
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
                          unawaited(
                            controller.player.setCrossfadeSeconds(val.round()),
                          );
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
            subtitle: const Text(
              'Keep playing recommendations when queue ends',
            ),
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
      (
        'Performance',
        [
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
              'Static glow, no seek ripple and no button bounce. With the visualizer off the player scene stops repainting, which cuts battery use.',
            ),
            value: identity.reducedEffects,
            onChanged: (val) async {
              TactileFeedback.selection();
              await controller.updateReducedEffects(val);
            },
          ),
        ],
      ),
      (
        'Discovery & Search',
        [
          PearSwitchTile(
            secondary: const Icon(Icons.travel_explore_rounded),
            title: const Text('Expanded Search Scope'),
            subtitle: const Text(
              'Include music videos, covers, and community uploads alongside official audio',
            ),
            value: identity.extendedSearch,
            onChanged: (val) async {
              TactileFeedback.selection();
              await identity.setExtendedSearch(val);
            },
          ),
        ],
      ),
      (
        'Storage & Cache',
        [
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
      if (!kIsWeb && Platform.isWindows)
        ('Audio engine', [const AudioEngineCard()]),
      (
        'About & Updates',
        [
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
                        shape: BoxShape.rectangle,
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
    ];

    return _NewSettings(sections: sections);
  }
}
/// Settings: a SETTINGS kicker and
/// title, then each numbered section as one angular panel. Wide windows add
/// a column of section names that scrolls to its section and marks the one
/// in view.
class _NewSettings extends StatefulWidget {
  final List<(String, List<Widget>)> sections;

  const _NewSettings({required this.sections});

  @override
  State<_NewSettings> createState() => _NewSettingsState();
}

class _NewSettingsState extends State<_NewSettings>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();

  /// A picked section's panel flashes once it is in place, 1 down to 0.
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  int? _flashed;
  List<GlobalKey> _keys = [];
  int _current = 0;

  /// True while a tap in the section list scrolls, so the list keeps the
  /// tapped name marked even when the last sections cannot reach the top.
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackCurrent);
  }

  @override
  void dispose() {
    _flash.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _trackCurrent() {
    if (_jumping || !_scroll.hasClients) return;
    var current = 0;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 1) {
      current = _keys.length - 1;
    } else {
      for (var i = 0; i < _keys.length; i++) {
        final box = _keys[i].currentContext?.findRenderObject();
        if (box == null) continue;
        final top = RenderAbstractViewport.of(
          box,
        ).getOffsetToReveal(box, 0).offset;
        if (top <= position.pixels + 24) current = i;
      }
    }
    if (current != _current) setState(() => _current = current);
  }

  Future<void> _jumpTo(int i) async {
    final target = _keys[i].currentContext;
    if (target == null) return;
    TactileFeedback.click();
    setState(() {
      _current = i;
      _jumping = true;
    });
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    _jumping = false;
    if (!mounted) return;
    _flashed = i;
    _flash.reverse(from: 1);
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.sections;
    if (_keys.length != sections.length) {
      _keys = [for (final _ in sections) GlobalKey()];
      _current = _current.clamp(0, sections.length - 1);
    }
    final short = pearShortScreen(context);
    // Sideways the section list beside the panels saves scrolling.
    final wide = MediaQuery.sizeOf(context).width >= (short ? 640 : 900);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The audio engine card sits flat inside its panel, not as a second card.
    final flatCards = theme.copyWith(
      cardTheme: const CardThemeData(
        color: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(),
      ),
    );

    final panels = SingleChildScrollView(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(16, short ? 8 : (wide ? 28 : 12), 16, 140),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!wide) ...[
                const _SettingsHeading(),
                const SizedBox(height: 20),
              ],
              for (final (i, (title, rows)) in sections.indexed)
                Padding(
                  key: _keys[i],
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _NewSectionTitle(
                        number: i + 1,
                        title: title,
                        active: wide && i == _current,
                      ),
                      const SizedBox(height: 10),
                      // Wide, the section in view carries an accent edge and
                      // tint, so it matches the name lit in the list.
                      AnimatedBuilder(
                        animation: _flash,
                        builder: (context, child) {
                          final active = wide && i == _current;
                          final flash = i == _flashed
                              ? Curves.easeOut.transform(_flash.value)
                              : 0.0;
                          return DecoratedBox(
                            key: ValueKey('settings_panel_$i'),
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  width: 3,
                                  color: active
                                      ? scheme.primary
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                            child: PearGlass(
                              // The rows paint their ink on this tint.
                              child: Material(
                                key: ValueKey('settings_tint_$i'),
                                animationDuration: Duration.zero,
                                color: scheme.primary.withValues(
                                  alpha: (active ? 0.05 : 0) + 0.16 * flash,
                                ),
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: Theme(
                          data: flatCards,
                          child: Column(children: rows),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: !wide
            ? panels
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 220,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(16, short ? 8 : 28, 8, 24),
                      children: [
                        const _SettingsHeading(),
                        SizedBox(height: short ? 12 : 24),
                        for (final (i, (title, _)) in sections.indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                mouseCursor: WidgetStateMouseCursor.clickable,
                                onTap: () => _jumpTo(i),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  height: 40,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  alignment: Alignment.centerLeft,
                                  decoration: i == _current
                                      ? PearGlassTokens.selectionPill(scheme)
                                      : const BoxDecoration(),
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: i == _current
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: Colors.white.withValues(
                                        alpha: i == _current ? 0.95 : 0.6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    color: Colors.white.withValues(alpha: PearGlassTokens.edge),
                  ),
                  Expanded(child: panels),
                ],
              ),
      ),
    );
  }
}

/// The SETTINGS kicker in the accent over the screen title.
class _SettingsHeading extends StatelessWidget {
  const _SettingsHeading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SETTINGS',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Preferences',
            style: (pearShortScreen(context)
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.headlineSmall)
                ?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// "01   Audio & Playback": the number in the accent and the name, both
/// larger and bolder than the rows below. [active] (the section in view)
/// puts the whole heading in the accent.
class _NewSectionTitle extends StatelessWidget {
  final int number;
  final String title;
  final bool active;

  const _NewSectionTitle({
    required this.number,
    required this.title,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: number.toString().padLeft(2, '0'),
              style: style.copyWith(
                color: accent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            TextSpan(
              text: '   $title',
              style: style.copyWith(
                color: active ? accent : Colors.white.withValues(alpha: 0.92),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
