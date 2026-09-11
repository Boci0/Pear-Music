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
      duration: const Duration(milliseconds: 170),
      reverseDuration: const Duration(milliseconds: 130),
      value: PlayerArtwork.showLyricsNotifier.value ? 1.0 : 0.0,
    );

    // Snappy, front-loaded curves:
    // Blur layer softens into frosted glass immediately
    _blurAnimation = CurvedAnimation(
      parent: _lyricsAnimController,
      curve: Curves.easeOutQuad,
      reverseCurve: Curves.easeInQuad,
    );

    // Lyrics fade in closely behind the blur (starting at ~25ms)
    _lyricsAnimation = CurvedAnimation(
      parent: _lyricsAnimController,
      curve: const Interval(0.12, 1.0, curve: Curves.easeOutQuad),
      reverseCurve: const Interval(0.0, 0.70, curve: Curves.easeInQuad),
    );

    // Sync button animates with lyrics
    _syncAnimation = CurvedAnimation(
      parent: _lyricsAnimController,
      curve: const Interval(0.12, 1.0, curve: Curves.easeOutQuad),
      reverseCurve: const Interval(0.0, 0.70, curve: Curves.easeInQuad),
    );

    PlayerArtwork.showLyricsNotifier.addListener(_onLyricsVisibilityChanged);
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

    final playerService = context.watch<PlayerService?>();
    final Widget glowWidget;
    if (playerService != null) {
      glowWidget = RhythmPulseBuilder(
        player: playerService,
        builder: (context, aura, _) {
          final alpha1 = (0.175 + (0.325 * aura)).clamp(0.0, 1.0);
          final alpha2 = (0.105 + (0.195 * aura)).clamp(0.0, 1.0);
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: baseShadowColor.withValues(alpha: alpha1),
                  blurRadius: 36.0,
                  spreadRadius: 2.0,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: baseShadowColor.withValues(alpha: alpha2),
                  blurRadius: 18.0,
                  spreadRadius: 1.0,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          );
        },
      );
    } else {
      glowWidget = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: baseShadowColor.withValues(alpha: 0.30),
              blurRadius: 36.0,
              spreadRadius: 2.0,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: baseShadowColor.withValues(alpha: 0.18),
              blurRadius: 18.0,
              spreadRadius: 1.0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      );
    }

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
              clipBehavior: Clip.antiAliasWithSaveLayer,
              child: AnimatedBuilder(
                animation: _lyricsAnimController,
                builder: (context, _) {
                  final isLyricsActive = _lyricsAnimController.value > 0.0;
                  final isLyricsFullyOpen = PlayerArtwork.showLyricsNotifier.value;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      crossfadeImage,
                      if (song != null && playerService != null && isLyricsActive)
                        FadeTransition(
                          opacity: _blurAnimation,
                          child: IgnorePointer(
                            ignoring: !isLyricsFullyOpen,
                            child: _buildBlurredGlassBackdrop(
                              scheme: scheme,
                              baseShadowColor: baseShadowColor,
                              radius: radius,
                              size: size,
                              song: song,
                              initialBytes: initialBytes,
                              effectiveNetworkUrl: effectiveNetworkUrl,
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
                                color: isLyricsFullyOpen
                                    ? Colors.white.withValues(alpha: 0.22)
                                    : Colors.white.withValues(alpha: 0.16),
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
                                      'Sync',
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
                          child: PlayerPillButton(
                            isCircle: true,
                            tooltip: isLyricsFullyOpen ? 'Show album artwork' : 'Show lyrics',
                            activeColor: baseShadowColor,
                            onTap: () => PlayerArtwork.toggleLyrics(),
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
                                color: Colors.white,
                              ),
                            ),
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

  Widget _buildBlurredGlassBackdrop({
    required ColorScheme scheme,
    required Color baseShadowColor,
    required BorderRadius radius,
    required double size,
    required Song? song,
    required Uint8List? initialBytes,
    required String? effectiveNetworkUrl,
  }) {
    const lowResPx = 64;
    final Widget lowResImage;
    if (effectiveNetworkUrl != null && effectiveNetworkUrl.isNotEmpty) {
      lowResImage = Image.network(
        effectiveNetworkUrl,
        width: size,
        height: size,
        cacheWidth: lowResPx,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(scheme),
      );
    } else if (initialBytes != null && initialBytes.isNotEmpty) {
      lowResImage = Image.memory(
        initialBytes,
        width: size,
        height: size,
        cacheWidth: lowResPx,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(scheme),
      );
    } else if (song != null) {
      final cached = ArtworkPalette.bytes(song);
      if (cached != null && cached.isNotEmpty) {
        lowResImage = Image.memory(
          cached,
          width: size,
          height: size,
          cacheWidth: lowResPx,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(scheme),
        );
      } else {
        lowResImage = _placeholder(scheme);
      }
    } else {
      lowResImage = _placeholder(scheme);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: ClipRRect(
            borderRadius: radius,
            clipBehavior: Clip.antiAliasWithSaveLayer,
            child: Transform.scale(
              scale: 1.12,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: lowResImage,
              ),
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.15),
                baseShadowColor.withValues(alpha: 0.14),
                Colors.black.withValues(alpha: 0.40),
              ],
              stops: const [0.0, 0.45, 1.0],
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
    return Hero(
      tag: 'player_artwork_${song.id}',
      child: Material(
        type: MaterialType.transparency,
        child: PlayerArtwork(
          song: song,
          artwork: isNetwork ? null : artwork,
          networkUrl: isNetwork ? song.artwork : null,
          size: size,
          accent: accent,
        ),
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
    final controller = context.watch<AppController>();
    final player = context.watch<PlayerService>();
    final isFav = controller.isFavorite(song.id);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isStream = song.sourceDeviceId == 'stream';
    final route = player.currentRouteType;

    return SizedBox(
      height: 96,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 58,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isStream)
                  IconButton(
                    icon: Icon(
                      Icons.download_rounded,
                      color: theme.colorScheme.tertiary,
                    ),
                    tooltip: 'Save to library',
                    onPressed: () => controller.saveStreamToLibrary(song),
                  )
                else
                  IconButton(
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
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Center(
                          child: Text(
                            song.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(height: 1.15),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
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
            player.isBufferingNext,
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
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
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
            color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
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
  final Widget child;
  final String? tooltip;
  final Color activeColor;
  final bool isCircle;
  final bool isActive;

  const PlayerPillButton({
    super.key,
    required this.onTap,
    required this.child,
    required this.activeColor,
    this.tooltip,
    this.isCircle = false,
    this.isActive = true,
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

    Widget button = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _isPressed ? 0.90 : (_isHovered ? 1.06 : 1.0),
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
              color: _isPressed
                  ? Colors.black.withValues(alpha: 0.70)
                  : (_isHovered
                      ? Colors.black.withValues(alpha: 0.58)
                      : Colors.black.withValues(alpha: 0.46)),
              border: Border.all(
                color: _isHovered
                    ? Colors.white.withValues(alpha: 0.45)
                    : Colors.white.withValues(alpha: 0.22),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
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

