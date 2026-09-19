import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/artwork_service.dart';
import '../../services/player_service.dart';
import 'lyric_sync_sheet.dart';
import 'lyrics_view.dart';
import 'player_console_dialog.dart';
import 'rhythm_pulse.dart';
import 'visual_synthesizer_bar.dart';
import '../tactile_button.dart';

/// Large album artwork container with rounded corners, ambient accent glow,
/// and synchronized lyrics toggle display.
class PlayerArtwork extends StatefulWidget {
  static final ValueNotifier<bool> showLyricsNotifier = ValueNotifier<bool>(false);
  static bool get isLyricsShowing => showLyricsNotifier.value;
  static void closeLyrics() => showLyricsNotifier.value = false;
  static void toggleLyrics() => showLyricsNotifier.value = !showLyricsNotifier.value;

  final Song? song;
  final Uint8List? artwork;
  final String? networkUrl;
  final double size;
  final Color? accent;
  const PlayerArtwork({
    super.key,
    this.song,
    this.artwork,
    this.networkUrl,
    this.size = 240,
    this.accent,
  });

  @override
  State<PlayerArtwork> createState() => _PlayerArtworkState();
}

class _PlayerArtworkState extends State<PlayerArtwork> with SingleTickerProviderStateMixin {
  late final AnimationController _lyricsAnimController;
  late final Animation<double> _blurAnimation;
  late final Animation<double> _lyricsAnimation;
  late final Animation<double> _syncAnimation;

  int _lyricsVersion = 0;

  @override
  void initState() {
    super.initState();
    _lyricsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 110),
      value: PlayerArtwork.showLyricsNotifier.value ? 1.0 : 0.0,
    );

    // Snappy, front-loaded curves:
    // Blur layer softens into frosted glass immediately
    _blurAnimation = CurvedAnimation(
      parent: _lyricsAnimController,
      curve: Curves.easeOutQuad,
      reverseCurve: Curves.easeInQuad,
    );

    // Lyrics fade in closely behind the blur (starting at ~11ms)
    _lyricsAnimation = CurvedAnimation(
      parent: _lyricsAnimController,
      curve: const Interval(0.08, 1.0, curve: Curves.easeOutQuad),
      reverseCurve: const Interval(0.0, 0.70, curve: Curves.easeInQuad),
    );

    // Sync button animates with lyrics
    _syncAnimation = CurvedAnimation(
      parent: _lyricsAnimController,
      curve: const Interval(0.08, 1.0, curve: Curves.easeOutQuad),
      reverseCurve: const Interval(0.0, 0.70, curve: Curves.easeInQuad),
    );

    PlayerArtwork.showLyricsNotifier.addListener(_onLyricsVisibilityChanged);
    ArtworkPalette.paletteNotifier.addListener(_onPaletteUpdated);
  }

  void _onPaletteUpdated() {
    if (mounted) setState(() {});
  }

  void _onLyricsVisibilityChanged() {
    if (!mounted) return;
    if (PlayerArtwork.showLyricsNotifier.value) {
      _lyricsAnimController.forward();
    } else {
      _lyricsAnimController.reverse();
    }
  }

  @override
  void dispose() {
    PlayerArtwork.showLyricsNotifier.removeListener(_onLyricsVisibilityChanged);
    ArtworkPalette.paletteNotifier.removeListener(_onPaletteUpdated);
    _lyricsAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(16);
    final size = widget.size;
    final song = widget.song;
    final networkUrl = widget.networkUrl;
    final artwork = widget.artwork;
    final baseShadowColor = (widget.accent ?? scheme.primary);
    final isAccentDark = ThemeData.estimateBrightnessForColor(baseShadowColor) == Brightness.dark;
    final isLight = ArtworkPalette.prefersDarkText(song);
    final useSynthesizer = context.select<AppController?, bool>(
      (c) => c?.identity.synthesizerBar ?? false,
    );

    final songArt = song?.artwork;
    final isNetwork = networkUrl != null || (songArt != null && songArt.startsWith('http'));
    final rawNetworkUrl = networkUrl ?? (isNetwork ? songArt : null);
    final effectiveNetworkUrl = rawNetworkUrl != null && rawNetworkUrl.isNotEmpty
        ? ArtworkService.optimizeArtworkUrl(rawNetworkUrl)
        : null;
    final initialBytes = artwork ?? (song != null ? ArtworkPalette.bytes(song) : null);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final targetPx = (size * dpr).round().clamp(96, 768);

    final Widget imageWidget;
    if (effectiveNetworkUrl != null && effectiveNetworkUrl.isNotEmpty) {
      imageWidget = Image.network(
        effectiveNetworkUrl,
        key: ValueKey('net_$effectiveNetworkUrl'),
        width: size,
        height: size,
        cacheWidth: targetPx,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame != null && song != null && !ArtworkPalette.hasResolved(song)) {
            ArtworkPalette.dominant(song);
          }
          return child;
        },
        errorBuilder: (_, _, _) {
          if (rawNetworkUrl != null && rawNetworkUrl != effectiveNetworkUrl) {
            return Image.network(
              rawNetworkUrl,
              width: size,
              height: size,
              cacheWidth: targetPx,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, _, _) => _placeholder(scheme),
            );
          }
          return _placeholder(scheme);
        },
      );
    } else if (initialBytes != null && initialBytes.isNotEmpty) {
      imageWidget = Image.memory(
        initialBytes,
        key: ValueKey('mem_${song?.id ?? initialBytes.hashCode}'),
        width: size,
        height: size,
        cacheWidth: targetPx,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(scheme),
      );
    } else if (song != null) {
      imageWidget = FutureBuilder<Uint8List?>(
        key: ValueKey('async_${song.id}'),
        future: ArtworkPalette.bytesAsync(song),
        initialData: initialBytes,
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? initialBytes;
          if (bytes == null || bytes.isEmpty) return _placeholder(scheme);
          return Image.memory(
            bytes,
            width: size,
            height: size,
            cacheWidth: targetPx,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(scheme),
          );
        },
      );
    } else {
      imageWidget = _placeholder(scheme);
    }

    final currentArtKey = effectiveNetworkUrl ??
        (song?.id ?? (initialBytes != null ? '${initialBytes.hashCode}' : 'placeholder'));

    final crossfadeImage = AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            ?currentChild,
          ],
        );
      },
      child: KeyedSubtree(
        key: ValueKey(currentArtKey),
        child: SizedBox.expand(child: imageWidget),
      ),
    );

    final playerService = context.read<PlayerService?>();
    final staticGlow = RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: baseShadowColor.withValues(alpha: 0.45),
              blurRadius: 36.0,
              spreadRadius: 2.0,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: baseShadowColor.withValues(alpha: 0.28),
              blurRadius: 18.0,
              spreadRadius: 1.0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
    );

    final Widget glowWidget;
    if (playerService != null) {
      glowWidget = RhythmPulseBuilder(
        player: playerService,
        child: staticGlow,
        builder: (context, aura, child) {
          final opacity = (0.38 + (0.62 * aura)).clamp(0.0, 1.0);
          return Opacity(
            opacity: opacity,
            child: child,
          );
        },
      );
    } else {
      glowWidget = staticGlow;
    }

    final Widget? glassBackdrop = (song != null && playerService != null)
        ? RepaintBoundary(
            child: ClipRRect(
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: Transform.scale(
                scale: 1.15,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: imageWidget,
                ),
              ),
            ),
          )
        : null;

    return Stack(
      alignment: Alignment.center,
      children: [
        glowWidget,
        RepaintBoundary(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 8.0,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: AnimatedBuilder(
                animation: _lyricsAnimController,
                child: glassBackdrop,
                builder: (context, cachedBackdrop) {
                  final isLyricsActive = _lyricsAnimController.value > 0.0;
                  final isLyricsFullyOpen = PlayerArtwork.showLyricsNotifier.value;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      crossfadeImage,
                      if (cachedBackdrop != null && isLyricsActive)
                        FadeTransition(
                          opacity: _blurAnimation,
                          child: IgnorePointer(
                            ignoring: !isLyricsFullyOpen,
                            child: cachedBackdrop,
                          ),
                        ),
                      // Calms busy bright artwork so dark lyrics stay readable.
                      if (cachedBackdrop != null && isLyricsActive && isLight)
                        FadeTransition(
                          opacity: _blurAnimation,
                          child: IgnorePointer(
                            child: Container(
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                        ),
                      // Equalizer spectrum visualizer stacked behind lyrics and border
                      if (song != null && playerService != null && useSynthesizer)
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: isLyricsFullyOpen,
                            child: ArtworkVisualizer(
                              player: playerService,
                              accentColor: baseShadowColor,
                            ),
                          ),
                        ),
                      if (song != null && playerService != null)
                        Visibility(
                          visible: isLyricsActive,
                          maintainState: true,
                          child: FadeTransition(
                            opacity: _lyricsAnimation,
                            child: LyricsView(
                              key: ValueKey('lyrics_${song.id}_$_lyricsVersion'),
                              song: song,
                              player: playerService,
                              accent: widget.accent,
                              size: size,
                              isVisible: isLyricsFullyOpen,
                            ),
                          ),
                        ),
                      // Razor-thin crisp border framing the big artwork
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: radius,
                              border: Border.all(
                                color: (isLyricsFullyOpen && isLight)
                                    ? Colors.black.withValues(alpha: 0.12)
                                    : (isLyricsFullyOpen
                                        ? Colors.white.withValues(alpha: 0.22)
                                        : Colors.white.withValues(alpha: 0.16)),
                                width: 1.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (song != null && playerService != null)
                        Positioned(
                          top: 10,
                          left: 10,
                          child: FadeTransition(
                            opacity: _syncAnimation,
                            child: IgnorePointer(
                              ignoring: !isLyricsFullyOpen,
                              child: PlayerPillButton(
                                tooltip: 'Lyrics timing & options',
                                activeColor: baseShadowColor,
                                isActive: false,
                                onTap: () {
                                  showLyricSyncSheet(
                                    context,
                                    song: song,
                                    player: playerService,
                                    onLyricsUpdated: () {
                                      setState(() {
                                        _lyricsVersion++;
                                      });
                                    },
                                  );
                                },
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.tune_rounded,
                                      size: 13,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 4.5),
                                    Text(
                                      'Timing',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (song != null && playerService != null)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PlayerPillButton(
                                isCircle: true,
                                isActive: useSynthesizer,
                                tooltip: useSynthesizer
                                    ? 'Hide visualizer'
                                    : 'Show visualizer',
                                activeColor: baseShadowColor,
                                onTap: () {
                                  final willEnable = !useSynthesizer;
                                  context.read<AppController?>()?.updateSynthesizerBar(willEnable);
                                },
                                child: Icon(
                                  useSynthesizer ? Icons.graphic_eq_rounded : Icons.equalizer_rounded,
                                  size: 16,
                                  color: useSynthesizer
                                      ? (isAccentDark ? Colors.white : const Color(0xFF141416))
                                      : Colors.white.withValues(alpha: 0.90),
                                ),
                              ),
                              const SizedBox(width: 8),
                              PlayerPillButton(
                                isCircle: true,
                                isActive: isLyricsFullyOpen,
                                tooltip: isLyricsFullyOpen ? 'Show album artwork' : 'Show lyrics',
                                activeColor: baseShadowColor,
                                onTap: () {
                                  final willOpen = !isLyricsFullyOpen;
                                  if (willOpen) {
                                    PlayerArtwork.showLyricsNotifier.value = true;
                                  } else {
                                    PlayerArtwork.closeLyrics();
                                  }
                                },
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 90),
                                  transitionBuilder: (child, anim) => FadeTransition(
                                    opacity: anim,
                                    child: child,
                                  ),
                                  child: Icon(
                                    isLyricsFullyOpen ? Icons.image_rounded : Icons.lyrics_rounded,
                                    key: ValueKey(isLyricsFullyOpen),
                                    size: 16,
                                    color: isLyricsFullyOpen
                                        ? (isAccentDark ? Colors.white : const Color(0xFF141416))
                                        : Colors.white.withValues(alpha: 0.90),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );

  }

  Widget _placeholder(ColorScheme scheme) {
    final size = widget.size;
    return Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.45,

        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Artwork wrapped in a Hero tag to animate from the bottom bar into the
/// player screen.
class PlayerArtworkHero extends StatelessWidget {
  final Song song;
  final Uint8List? artwork;
  final double size;
  final Color? accent;

  const PlayerArtworkHero({
    super.key,
    required this.song,
    this.artwork,
    this.size = 240,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');
    return Material(
      type: MaterialType.transparency,
      child: PlayerArtwork(
        song: song,
        artwork: isNetwork ? null : artwork,
        networkUrl: isNetwork ? song.artwork : null,
        size: size,
        accent: accent,
      ),
    );
  }
}

/// Song title, artist/device info line, and favorite toggle button.
class PlayerSongInfo extends StatelessWidget {
  final Song song;
  const PlayerSongInfo({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final isFav = context.select<AppController, bool>(
      (c) => c.isFavorite(song.id),
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isStream = song.sourceDeviceId == 'stream';
    final route = context.select<PlayerService, StreamRouteType>(
      (p) => p.currentRouteType,
    );
    final isConnecting = context.select<PlayerService, bool>(
      (p) => p.isBufferingNext,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 96, maxHeight: 114),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 58, maxHeight: 72),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isStream)
                  TactileIconButton(
                    icon: Icon(
                      Icons.download_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    tooltip: 'Save to library',
                    onPressed: () => controller.saveStreamToLibrary(song),
                  )
                else
                  TactileIconButton(
                    icon: Icon(
                      Icons.sensors_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    tooltip: 'Start Radio mix',
                    onPressed: () => controller.startRadio(song),
                  ),
                Expanded(
                  child: Tooltip(
                    message: 'Tap or long-press to copy title',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _copyTitle(context, song.title),
                      onLongPress: () => _copyTitle(context, song.title),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Center(
                          child: Text(
                            song.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(height: 1.24),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                TactileIconButton(
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: isFav ? 'Remove from favorites' : 'Add to favorites',
                  onPressed: () => controller.toggleFavorite(song.id, song: song),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _buildSourceInfo(
            context,
            isStream,
            route,
            isConnecting,
            scheme,
            theme,
          ),
        ],
      ),
    );
  }

  Widget _buildSourceInfo(
    BuildContext context,
    bool isStream,
    StreamRouteType route,
    bool isConnecting,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    final Widget content;

    if (isStream && isConnecting) {
      content = Row(
        key: const ValueKey('source_buffering'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Connecting to Pear Radio...',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    } else if (isStream) {
      content = GestureDetector(
        key: const ValueKey('source_stream'),
        onLongPress: () => PlayerConsoleDialog.show(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.radio_rounded,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              'Pear Radio',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    } else {
      final label = song.sourceDeviceId == null ? 'Local Library' : 'Shared from peer';
      content = Row(
        key: ValueKey('source_local_${song.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            song.sourceDeviceId == null ? Icons.folder_outlined : Icons.devices_rounded,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return SizedBox(
      height: 24,
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: content,
        ),
      ),
    );
  }

  static Future<void> _copyTitle(BuildContext context, String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    if (context.mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied "$title" to clipboard'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class PlayerPillButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final String? tooltip;
  final Color activeColor;
  final bool isCircle;
  final bool isActive;

  const PlayerPillButton({
    super.key,
    required this.onTap,
    this.onLongPress,
    required this.child,
    required this.activeColor,
    this.tooltip,
    this.isCircle = false,
    this.isActive = false,
  });

  @override
  State<PlayerPillButton> createState() => _PlayerPillButtonState();
}

class _PlayerPillButtonState extends State<PlayerPillButton> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final pillRadius = widget.isCircle ? BorderRadius.circular(20) : BorderRadius.circular(16);
    final accent = widget.activeColor;
    final isActive = widget.isActive;

    final Color bgColor;
    final Color borderColor;
    final Color shadowColor;

    if (isActive) {
      bgColor = _isPressed
          ? accent.withValues(alpha: 0.90)
          : (_isHovered ? accent.withValues(alpha: 0.96) : accent);
      borderColor = Colors.white.withValues(alpha: _isHovered ? 0.45 : 0.30);
      shadowColor = accent.withValues(alpha: 0.40);
    } else {
      bgColor = Colors.black.withValues(
        alpha: _isPressed ? 0.72 : (_isHovered ? 0.62 : 0.52),
      );
      borderColor = Colors.white.withValues(
        alpha: _isHovered ? 0.34 : 0.22,
      );
      shadowColor = Colors.black.withValues(alpha: 0.35);
    }

    Widget button = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          TactileFeedback.click();
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        onLongPress: widget.onLongPress != null
            ? () {
                TactileFeedback.click();
                widget.onLongPress!();
              }
            : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _isPressed ? 0.92 : (_isHovered ? 1.05 : 1.0),
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOutQuad,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOutQuad,
            padding: widget.isCircle
                ? const EdgeInsets.all(7.5)
                : const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              shape: widget.isCircle ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: widget.isCircle ? null : pillRadius,
              color: bgColor,
              border: Border.all(
                color: borderColor,
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: 6.0,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: widget.child,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

