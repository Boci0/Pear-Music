import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';

/// Modal bottom sheet allowing users to fine-tune lyrics synchronization timing
/// or search and select alternate lyrics from LRCLIB.
Future<void> showLyricSyncSheet(
  BuildContext context, {
  required Song song,
  required PlayerService player,
  bool initialSearchOpen = false,
  VoidCallback? onLyricsUpdated,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => _LyricSyncSheetContent(
      song: song,
      player: player,
      initialSearchOpen: initialSearchOpen,
      onLyricsUpdated: onLyricsUpdated,
    ),
  );
}

class _LyricSyncSheetContent extends StatefulWidget {
  final Song song;
  final PlayerService player;
  final bool initialSearchOpen;
  final VoidCallback? onLyricsUpdated;

  const _LyricSyncSheetContent({
    required this.song,
    required this.player,
    this.initialSearchOpen = false,
    this.onLyricsUpdated,
  });

  @override
  State<_LyricSyncSheetContent> createState() => _LyricSyncSheetContentState();
}

class _LyricSyncSheetContentState extends State<_LyricSyncSheetContent> {
  int _currentOffsetMs = 0;
  bool _isLoadingOffset = true;

  late final TextEditingController _searchController;
  bool _isSearching = false;
  List<LrcCandidate> _candidates = const [];
  bool _hasSearched = false;

  String? _localAudioPath;
  String? _currentRawLrc;
  int? _selectedCandidateId;

  static String _normalizeLrc(String content) {
    return content
        .replaceAll(RegExp(r'\[offset:\s*[+-]?\d+\s*\]', caseSensitive: false), '')
        .replaceAll('\r\n', '\n')
        .trim();
  }

  @override
  void initState() {
    super.initState();
    final library = widget.player.library;
    if (library.hasSongFile(widget.song)) {
      _localAudioPath = library.songFile(widget.song).path;
    }

    _searchController = TextEditingController(
      text: LyricsService.cleanTrackTitle(widget.song.title),
    );

    _loadCurrentOffset();
    if (widget.initialSearchOpen) {
      _performSearch();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentOffset() async {
    final offset = await LyricsService.getOffset(
      widget.song,
      localAudioPath: _localAudioPath,
    );
    final raw = await LyricsService.getRawLrc(
      widget.song,
      localAudioPath: _localAudioPath,
    );
    if (!mounted) return;
    setState(() {
      _currentOffsetMs = offset;
      _currentRawLrc = raw;
      _isLoadingOffset = false;
    });
  }

  Future<void> _adjustOffset(int deltaMs) async {
    final newOffset = _currentOffsetMs + deltaMs;
    setState(() {
      _currentOffsetMs = newOffset;
    });
    await LyricsService.setOffset(
      widget.song,
      newOffset,
      localAudioPath: _localAudioPath,
    );
    widget.onLyricsUpdated?.call();
  }

  Future<void> _resetOffset() async {
    setState(() {
      _currentOffsetMs = 0;
    });
    await LyricsService.setOffset(
      widget.song,
      0,
      localAudioPath: _localAudioPath,
    );
    widget.onLyricsUpdated?.call();
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _isSearching) return;

    setState(() {
      _isSearching = true;
      _hasSearched = true;
    });

    try {
      final results = await LyricsService.searchCandidates(
        widget.song,
        query: query,
        duration: widget.player.duration,
      );
      if (!mounted) return;
      setState(() {
        _candidates = results;
        _isSearching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _candidates = const [];
        _isSearching = false;
      });
    }
  }

  Future<void> _applyCandidate(LrcCandidate candidate) async {
    await LyricsService.applyCandidate(
      widget.song,
      candidate,
      localAudioPath: _localAudioPath,
    );
    if (mounted) {
      setState(() {
        _currentRawLrc = candidate.lyricsContent;
        _currentOffsetMs = LyricsService.extractOffsetMs(candidate.lyricsContent);
        _selectedCandidateId = candidate.id;
      });
    }
    widget.onLyricsUpdated?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            candidate.hasSyncedLyrics
                ? 'Applied synchronized lyrics from ${candidate.artistName}'
                : 'Applied lyrics from ${candidate.artistName}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _formatDuration(double seconds) {
    final totalSec = seconds.round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.tune_rounded, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Lyrics Timing & Options',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 16),
              // Offset Control Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Sync Offset',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.70),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isLoadingOffset
                          ? '···'
                          : (_currentOffsetMs == 0
                              ? '0.0s (In Sync)'
                              : '${_currentOffsetMs > 0 ? '+' : ''}${(_currentOffsetMs / 1000.0).toStringAsFixed(1)}s (${_currentOffsetMs > 0 ? '+' : ''}${_currentOffsetMs}ms)'),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: _currentOffsetMs == 0
                            ? Colors.white
                            : scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Earlier',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.50),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildOffsetButton('-0.5s', () => _adjustOffset(-500)),
                                const SizedBox(width: 6),
                                _buildOffsetButton('-0.1s', () => _adjustOffset(-100)),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: _currentOffsetMs == 0 ? null : _resetOffset,
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Reset'),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Later',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.50),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildOffsetButton('+0.1s', () => _adjustOffset(100)),
                                const SizedBox(width: 6),
                                _buildOffsetButton('+0.5s', () => _adjustOffset(500)),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Negative shows lyrics earlier; positive delays them.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Search Alternate Section
              Text(
                'Search Alternate Lyrics',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Song or artist name...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onSubmitted: (_) => _performSearch(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _isSearching ? null : _performSearch,
                    icon: _isSearching
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search_rounded, size: 16),
                    label: const Text('Search'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ],
              ),
              if (_hasSearched) ...[
                const SizedBox(height: 12),
                if (_candidates.isEmpty && !_isSearching)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        'No alternate lyrics found on LRCLIB.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.50),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _candidates.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final c = _candidates[index];
                      final trackDur = widget.player.duration?.inSeconds ?? 0;
                      final durSec = c.duration.round();
                      final diff = durSec - trackDur;
                      final isCloseDuration = trackDur > 0 && diff.abs() <= 3;

                      final normalizedCurrent = _normalizeLrc(_currentRawLrc ?? '');
                      final int activeCandidateIndex = _selectedCandidateId != null
                          ? _candidates.indexWhere((cand) => cand.id == _selectedCandidateId)
                          : (normalizedCurrent.isNotEmpty
                              ? _candidates.indexWhere((cand) =>
                                  _normalizeLrc(cand.lyricsContent) == normalizedCurrent)
                              : -1);

                      final bool isCurrent = index == activeCandidateIndex;

                      final String durBadgeText;
                      if (trackDur > 0) {
                        if (diff == 0) {
                          durBadgeText = '${_formatDuration(c.duration)} • Match';
                        } else if (diff > 0) {
                          durBadgeText = '${_formatDuration(c.duration)} (+${diff}s)';
                        } else {
                          durBadgeText = '${_formatDuration(c.duration)} (${diff}s)';
                        }
                      } else {
                        durBadgeText = _formatDuration(c.duration);
                      }

                      return Container(
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? scheme.primary.withValues(alpha: 0.12)
                              : scheme.surfaceContainerHighest.withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isCurrent
                                ? scheme.primary.withValues(alpha: 0.45)
                                : (isCloseDuration
                                    ? scheme.primary.withValues(alpha: 0.25)
                                    : Colors.white.withValues(alpha: 0.06)),
                            width: isCurrent ? 1.2 : 0.8,
                          ),
                        ),
                        child: ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  c.trackName.isNotEmpty
                                      ? c.trackName
                                      : widget.song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: isCurrent ? scheme.primary : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Duration Badge
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isCloseDuration
                                      ? scheme.primary.withValues(alpha: 0.20)
                                      : Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  durBadgeText,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isCloseDuration
                                        ? scheme.primary
                                        : Colors.white.withValues(alpha: 0.70),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              // Synced Badge
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.hasSyncedLyrics
                                      ? scheme.secondary.withValues(alpha: 0.18)
                                      : Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  c.hasSyncedLyrics ? 'Synced' : 'Plain',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: c.hasSyncedLyrics
                                        ? scheme.secondary
                                        : Colors.white.withValues(alpha: 0.60),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 3),
                              Text(
                                '${c.artistName}${c.albumName.isNotEmpty ? ' • ${c.albumName}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white.withValues(alpha: 0.65),
                                ),
                              ),
                              if (c.snippet.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  '“${c.snippet}”',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: Colors.white.withValues(alpha: 0.40),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          trailing: isCurrent
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: scheme.primary.withValues(alpha: 0.35),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.check_rounded,
                                        size: 14,
                                        color: scheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Active',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : FilledButton.tonal(
                                  onPressed: () => _applyCandidate(c),
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                  ),
                                  child: const Text('Apply', style: TextStyle(fontSize: 11.5)),
                                ),
                        ),
                      );
                    },
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOffsetButton(String label, VoidCallback onPressed) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
