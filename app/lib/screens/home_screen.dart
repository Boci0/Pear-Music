import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/identity_service.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/song_tile.dart';
import '../widgets/tactile_button.dart';

/// Library tab: drag & drop (Windows) or picker, then play.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isSelecting = false;
  bool _isSearching = false;
  bool _showOnlyFavorites = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  void _toggleSelection(String songId, bool selected) {
    setState(() {
      if (selected) {
        _selectedIds.add(songId);
      } else {
        _selectedIds.remove(songId);
      }
    });
  }

  void _selectAll(List<Song> songs) {
    setState(() {
      if (_selectedIds.length == songs.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(songs.map((s) => s.id));
      }
    });
  }

  Future<void> _batchDelete(AppController controller, List<Song> songs) async {
    if (_selectedIds.isEmpty) return;
    final selectedSongs = songs
        .where((s) => _selectedIds.contains(s.id))
        .toList();
    final count = selectedSongs.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $count ${count == 1 ? "song" : "songs"}?'),
        content: const Text(
          'This permanently deletes the selected songs from this device and '
          'removes them from your library and playlists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove All'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.removeSongs(selectedSongs);
      if (mounted) {
        setState(() {
          _isSelecting = false;
          _selectedIds.clear();
        });
      }
    }
  }

  void _batchAddToQueue(AppController controller, List<Song> songs) {
    if (_selectedIds.isEmpty) return;
    final selectedSongs = songs
        .where((s) => _selectedIds.contains(s.id))
        .toList();
    controller.addSongsToQueue(selectedSongs);
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _batchAddToPlaylist(
    AppController controller,
    List<Song> songs,
  ) async {
    if (_selectedIds.isEmpty) return;
    final selectedSongs = songs
        .where((s) => _selectedIds.contains(s.id))
        .toList();
    final playlists = controller.library.playlists;
    final playlist = await showModalBottomSheet<Playlist>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Add ${selectedSongs.length} songs to playlist',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            if (playlists.isEmpty)
              const ListTile(title: Text('No playlists created yet'))
            else
              ...playlists.map(
                (p) => ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  subtitle: Text('${p.songIds.length} songs'),
                  onTap: () => Navigator.pop(ctx, p),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create new playlist'),
              onTap: () async {
                Navigator.pop(ctx);
                await _showCreatePlaylistDialog(controller, selectedSongs);
              },
            ),
          ],
        ),
      ),
    );
    if (playlist != null) {
      for (final song in selectedSongs) {
        await controller.library.addSongToPlaylist(playlist.id, song.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${selectedSongs.length} songs to ${playlist.name}',
            ),
          ),
        );
        setState(() {
          _isSelecting = false;
          _selectedIds.clear();
        });
      }
    }
  }

  Future<void> _showCreatePlaylistDialog(
    AppController controller,
    List<Song> selectedSongs,
  ) async {
    final nameController = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('New Playlist'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Playlist name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        final p = await controller.library.createPlaylist(name);
        for (final song in selectedSongs) {
          await controller.library.addSongToPlaylist(p.id, song.id);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Added ${selectedSongs.length} songs to ${p.name}'),
            ),
          );
          setState(() {
            _isSelecting = false;
            _selectedIds.clear();
          });
        }
      }
    } finally {
      nameController.dispose();
    }
  }

  /// One library row, shared by the single and multi-column lists.
  Widget _tileFor(
    Song song,
    List<Song> songs,
    String? currentSongId, {
    required String sourceId,
    required String sourceTitle,
  }) {
    return RepaintBoundary(
      child: SongTile(
        key: ValueKey(song.id),
        song: song,
        queue: songs,
        sourceId: sourceId,
        sourceTitle: sourceTitle,
        isCurrent: currentSongId == song.id,
        isSelecting: _isSelecting,
        isSelected: _selectedIds.contains(song.id),
        onSelectionChanged: (val) => _toggleSelection(song.id, val ?? false),
        onLongPress: () {
          setState(() {
            _isSelecting = true;
            _selectedIds.add(song.id);
          });
        },
      ),
    );
  }

  /// The song list sliver. Wide windows lay the songs out in 2-3 columns so
  /// the list does not stretch into one very long row; phones keep the plain
  /// single column.
  Widget _songsSliver(
    List<Song> songs,
    String? currentSongId, {
    required String sourceId,
    required String sourceTitle,
  }) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.crossAxisExtent / 460).floor().clamp(1, 3);

        int? findIndex(Key key) {
          final valueKey = key as ValueKey<String>?;
          if (valueKey == null) return null;
          final index = songs.indexWhere((s) => s.id == valueKey.value);
          return index >= 0 ? index : null;
        }

        if (columns <= 1) {
          return SliverFixedExtentList.builder(
            itemExtent: 61.0,
            itemCount: songs.length,
            findChildIndexCallback: findIndex,
            itemBuilder: (context, i) => _tileFor(
              songs[i],
              songs,
              currentSongId,
              sourceId: sourceId,
              sourceTitle: sourceTitle,
            ),
          );
        }

        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: 61.0,
            crossAxisSpacing: 10,
          ),
          itemCount: songs.length,
          findChildIndexCallback: findIndex,
          itemBuilder: (context, i) => _tileFor(
            songs[i],
            songs,
            currentSongId,
            sourceId: sourceId,
            sourceTitle: sourceTitle,
          ),
        );
      },
    );
  }

  /// Shared search field: the phone header shows it only in search mode while
  /// wide desktop headers keep it visible all the time.
  Widget _buildLibrarySearchField({required bool autofocus}) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autofocus: autofocus,
        style: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search library...',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    setState(() {
                      _searchQuery = '';
                      _searchController.clear();
                    });
                  },
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 0,
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
        ),
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    List<Song> rawSongs = _showOnlyFavorites
        ? controller.favoriteSongs
        : controller.songs;

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      rawSongs = rawSongs.where((s) => s.lowerTitle.contains(q)).toList();
    }

    final songs = controller.getSortedSongs(rawSongs);
    final theme = Theme.of(context);
    final currentSongId = controller.player.currentSong?.id;

    final Widget content;
    if (_isSearching) {
      content = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (songs.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  _showOnlyFavorites
                      ? 'No matching favorites'
                      : 'No matching songs in library',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24, top: 8),
              sliver: _songsSliver(
                songs,
                currentSongId,
                sourceId: 'search',
                sourceTitle: 'Search',
              ),
            ),
        ],
      );
    } else {
      content = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Row(
                children: [
                  _FilterPill(
                    key: const ValueKey('pill_all'),
                    label: 'All (${controller.songs.length})',
                    isSelected: !_showOnlyFavorites,
                    onTap: () => setState(() => _showOnlyFavorites = false),
                  ),
                  const SizedBox(width: 6),
                  _FilterPill(
                    key: const ValueKey('pill_favorites'),
                    icon: _showOnlyFavorites
                        ? Icons.favorite
                        : Icons.favorite_border,
                    label: 'Favorites (${controller.favoriteSongs.length})',
                    isSelected: _showOnlyFavorites,
                    onTap: () => setState(() => _showOnlyFavorites = true),
                  ),
                  const SizedBox(width: 6),
                  _FilterPill(
                    key: const ValueKey('pill_sort'),
                    icon: Icons.sort_rounded,
                    label: _sortLabel(controller.sortOption),
                    isSelected: false,
                    onTap: () => _showSortSheet(context, controller),
                  ),
                  const SizedBox(width: 6),
                  if (songs.isNotEmpty) ...[
                    _FilterPill(
                      key: const ValueKey('pill_shuffle'),
                      icon: Icons.shuffle_rounded,
                      label: 'Shuffle',
                      isSelected: false,
                      onTap: () {
                        TactileFeedback.click();
                        final list = List<Song>.from(songs);
                        list.shuffle();
                        if (!controller.player.shuffle) {
                          controller.player.toggleShuffle();
                        }
                        controller.playSong(
                          list[Random().nextInt(list.length)],
                          queue: list,
                          sourceId: _showOnlyFavorites
                              ? 'favorites'
                              : 'library',
                          sourceTitle: _showOnlyFavorites
                              ? 'Favorites'
                              : 'Library',
                        );
                      },
                    ),
                  ],
                  const SizedBox(width: 6),
                  _FilterPill(
                    key: const ValueKey('pill_select'),
                    icon: Icons.checklist_rounded,
                    label: _isSelecting ? 'Done' : null,
                    tooltip: _isSelecting ? 'Finish selecting' : 'Select songs',
                    isSelected: _isSelecting,
                    onTap: () {
                      setState(() {
                        _isSelecting = !_isSelecting;
                        if (!_isSelecting) _selectedIds.clear();
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _showOnlyFavorites
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                ),
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.16,
                                    ),
                                    blurRadius: 24,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.favorite_border_rounded,
                                size: 36,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'No favorite songs yet',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Tap the heart icon on any local or online song to add it to your favorites.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _EmptyState(onAdd: () => controller.addFilesFromPicker()),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 140),
              sliver: _songsSliver(
                songs,
                currentSongId,
                sourceId: _showOnlyFavorites ? 'favorites' : 'library',
                sourceTitle: _showOnlyFavorites ? 'Favorites' : 'Library',
              ),
            ),
        ],
      );
    }

    Widget body = content;
    if (_isDesktop) {
      body = DropTarget(
        onDragDone: (details) {
          controller.addDroppedFiles(
            details.files.map((f) => File(f.path)).toList(),
          );
        },
        child: content,
      );
    }

    final Widget headerContent;
    var headerActions = const <Widget>[];
    if (_isSearching) {
      headerContent = Row(
        key: const ValueKey('header_search'),
        children: [
          TactileIconButton(
            tooltip: 'Close search',
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              FocusScope.of(context).unfocus();
              setState(() {
                _isSearching = false;
                _searchQuery = '';
                _searchController.clear();
              });
            },
          ),
          const SizedBox(width: 4),
          Expanded(child: _buildLibrarySearchField(autofocus: true)),
        ],
      );
    } else if (_isSelecting) {
      headerContent = Row(
        key: const ValueKey('header_selecting'),
        children: [
          TactileIconButton(
            tooltip: 'Cancel selection',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _isSelecting = false;
              _selectedIds.clear();
            }),
          ),
          const SizedBox(width: 4),
          Text(
            '${_selectedIds.length} selected',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
      final nothingSelected = _selectedIds.isEmpty;
      headerActions = [
        TactileIconButton(
          tooltip: _selectedIds.length == songs.length
              ? 'Deselect all'
              : 'Select all',
          icon: Icon(
            _selectedIds.length == songs.length
                ? Icons.deselect
                : Icons.select_all,
          ),
          onPressed: () => _selectAll(songs),
        ),
        TactileIconButton(
          tooltip: 'Add to queue',
          icon: const Icon(Icons.queue_music_rounded),
          color: nothingSelected ? theme.disabledColor : null,
          onPressed: nothingSelected
              ? null
              : () => _batchAddToQueue(controller, songs),
        ),
        TactileIconButton(
          tooltip: 'Add to playlist',
          icon: const Icon(Icons.playlist_add),
          color: nothingSelected ? theme.disabledColor : null,
          onPressed: nothingSelected
              ? null
              : () => _batchAddToPlaylist(controller, songs),
        ),
        TactileIconButton(
          tooltip: 'Delete selected',
          icon: const Icon(Icons.delete_outline),
          color: nothingSelected
              ? theme.disabledColor
              : theme.colorScheme.error,
          onPressed: nothingSelected
              ? null
              : () => _batchDelete(controller, songs),
        ),
      ];
    } else {
      final isWideHeader = MediaQuery.sizeOf(context).width >= 900;
      if (isWideHeader) {
        // Desktop keeps the search field in the header at all times instead of
        // hiding it behind an icon.
        headerContent = Row(
          key: const ValueKey('header_default'),
          children: [
            const PearTabTitle('Library'),
            const SizedBox(width: 24),
            SizedBox(
              width: 360,
              child: _buildLibrarySearchField(autofocus: false),
            ),
          ],
        );
      } else {
        headerContent = const PearTabTitle(
          'Library',
          key: ValueKey('header_default'),
        );
      }
      headerActions = [
        if (!isWideHeader)
          TactileIconButton(
            tooltip: 'Search library',
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => _isSearching = true),
          ),
        TactileIconButton(
          tooltip: 'Add audio files',
          icon: const Icon(Icons.add),
          onPressed: () => controller.addFilesFromPicker(),
        ),
        PearMenuButton<String>(
          tooltip: 'Library profile',
          icon: Icons.import_export,
          onSelected: (value) async {
            if (value == 'import') {
              await _showLibraryProfileImportDialog(context, controller);
            } else if (value == 'export') {
              await controller.exportLibraryProfile();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'import',
              child: Text('Import library profile'),
            ),
            PopupMenuItem(
              value: 'export',
              child: Text('Export library profile'),
            ),
          ],
        ),
      ];
    }

    return CallbackShortcuts(
      bindings: {
        // Desktop conveniences: Ctrl+F focuses the library search field and
        // Escape backs out of search or selection, like a native window.
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (MediaQuery.sizeOf(context).width >= 900) {
            _searchFocusNode.requestFocus();
          } else if (!_isSearching) {
            setState(() => _isSearching = true);
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_isSelecting) {
            setState(() {
              _isSelecting = false;
              _selectedIds.clear();
            });
          } else if (_searchQuery.isNotEmpty) {
            setState(() {
              _searchQuery = '';
              _searchController.clear();
            });
          } else if (_isSearching) {
            setState(() => _isSearching = false);
          }
        },
      },
      child: Scaffold(
        appBar: PearAppBar(
          title: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            // Sequenced crossfade: the leaving header fades out in the first
            // half before the arriving one fades in, so the pear + tab title
            // never ghost over the search field mid-swap.
            switchInCurve: const Interval(
              0.45,
              1.0,
              curve: Curves.easeOutCubic,
            ),
            switchOutCurve: const Interval(
              0.55,
              1.0,
              curve: Curves.easeInCubic,
            ),
            // Keep both the outgoing and incoming headers pinned to the leading
            // edge. The default layout centres its children in a Stack, which
            // made the pear + tab title drift to the middle of the bar during
            // the crossfade into search (the search header is full width while
            // the title is min width).
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: AlignmentDirectional.centerStart,
              children: [...previousChildren, ?currentChild],
            ),
            child: headerContent,
          ),
          actions: headerActions,
        ),
        body: body,
      ),
    );
  }
}

class _FilterPill extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterPill({
    super.key,
    this.label,
    this.icon,
    this.tooltip,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_FilterPill> createState() => _FilterPillState();
}

class _FilterPillState extends State<_FilterPill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    final bgColor = widget.isSelected
        ? primary.withValues(alpha: _isHovered ? 0.28 : 0.20)
        : (_isHovered
              ? Colors.white.withValues(alpha: 0.09)
              : Colors.white.withValues(alpha: 0.05));

    final textColor = widget.isSelected
        ? primary
        : theme.colorScheme.onSurfaceVariant.withValues(
            alpha: _isHovered ? 1.0 : 0.9,
          );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: TactileBounce(
        scaleDown: 0.95,
        duration: const Duration(milliseconds: 80),
        onTap: widget.onTap,
        tooltip: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutQuad,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 15, color: textColor),
                const SizedBox(width: 6),
              ],
              if (widget.label != null)
                Text(
                  widget.label!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: textColor,
                    letterSpacing: -0.1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showSortSheet(BuildContext context, AppController controller) {
  final theme = Theme.of(context);
  final primary = theme.colorScheme.primary;

  showModalBottomSheet(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Sort Library',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.calendar_today_rounded,
                color: controller.sortOption == SortOption.dateAdded
                    ? primary
                    : null,
              ),
              title: const Text('Date Added'),
              trailing: controller.sortOption == SortOption.dateAdded
                  ? Icon(Icons.check_rounded, color: primary)
                  : null,
              onTap: () {
                TactileFeedback.selection();
                controller.setSortOption(SortOption.dateAdded);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.sort_by_alpha_rounded,
                color: controller.sortOption == SortOption.title
                    ? primary
                    : null,
              ),
              title: const Text('Title (A-Z)'),
              trailing: controller.sortOption == SortOption.title
                  ? Icon(Icons.check_rounded, color: primary)
                  : null,
              onTap: () {
                TactileFeedback.selection();
                controller.setSortOption(SortOption.title);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.data_usage_rounded,
                color: controller.sortOption == SortOption.size
                    ? primary
                    : null,
              ),
              title: const Text('File Size'),
              trailing: controller.sortOption == SortOption.size
                  ? Icon(Icons.check_rounded, color: primary)
                  : null,
              onTap: () {
                TactileFeedback.selection();
                controller.setSortOption(SortOption.size);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

String _sortLabel(SortOption option) {
  switch (option) {
    case SortOption.dateAdded:
      return 'Recent';
    case SortOption.title:
      return 'Title';
    case SortOption.size:
      return 'Size';
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.16),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Icon(
                Icons.library_music_rounded,
                size: 38,
                color: primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Your music library is empty',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap "Add music" to pick audio files.\nOn Windows you can also drag & drop files here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 22),
            TactileBounce(
              onTap: onAdd,
              scaleDown: 0.94,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                onPressed: null,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add music'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the modal progress dialog used by the library profile importer.
Future<void> _showLibraryProfileImportDialog(
  BuildContext context,
  AppController controller,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LibraryProfileImportDialog(controller: controller),
  );
}

class _LibraryProfileImportDialog extends StatefulWidget {
  final AppController controller;

  const _LibraryProfileImportDialog({required this.controller});

  @override
  State<_LibraryProfileImportDialog> createState() =>
      _LibraryProfileImportDialogState();
}

class _LibraryProfileImportDialogState
    extends State<_LibraryProfileImportDialog> {
  String _status = 'Choosing a profile file…';
  String _phase = '';
  int _index = 0;
  int _count = 0;
  int _bytes = 0;
  int _totalBytes = 0;
  double _speedBytesPerSec = 0;
  DateTime _startedAt = DateTime.now();
  bool _timerStarted = false;
  Duration _elapsed = Duration.zero;
  Timer? _clock;
  int _lastBytes = 0;
  DateTime _lastSample = DateTime.now();
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_timerStarted) return;
      setState(() => _elapsed = DateTime.now().difference(_startedAt));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  static String _fmtBytes(num bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${bytes.round()} B';
  }

  static String _fmtDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// Live byte progress from the fetcher. UI updates are throttled and the
  /// speed is smoothed so rapid progress lines do not cause janky text.
  void _handleBytes(int downloaded, int total) {
    final now = DateTime.now();
    final deltaBytes = downloaded - _lastBytes;
    final deltaMs = now.difference(_lastSample).inMilliseconds;
    if (deltaBytes < 0) {
      _lastBytes = downloaded;
      _lastSample = now;
      _speedBytesPerSec = 0;
    } else if (deltaMs > 0) {
      final instant = deltaBytes * 1000 / deltaMs;
      _speedBytesPerSec = _speedBytesPerSec <= 0
          ? instant
          : _speedBytesPerSec * 0.7 + instant * 0.3;
      _lastSample = now;
      _lastBytes = downloaded;
    }
    _bytes = downloaded;
    _totalBytes = total;
    if (now.difference(_lastUiUpdate).inMilliseconds >= 150 && mounted) {
      _lastUiUpdate = now;
      setState(() {});
    }
  }

  String get _detailLine {
    if (_totalBytes <= 0) {
      if (_bytes > 0) return _fmtBytes(_bytes);
      return _phase.isNotEmpty ? _phase : 'Preparing…';
    }
    final speed = _speedBytesPerSec > 0
        ? ' at ${_fmtBytes(_speedBytesPerSec)}/s'
        : '';
    return '${_fmtBytes(_bytes)} of ${_fmtBytes(_totalBytes)}$speed';
  }

  Future<void> _run() async {
    final navigator = Navigator.of(context);
    final result = await widget.controller.importLibraryProfile(
      onStatus: (status) {
        if (!mounted) return;
        setState(() {
          if (status.startsWith('Fetching')) {
            _status = status;
            _phase = '';
            if (!_timerStarted) {
              _timerStarted = true;
              _startedAt = DateTime.now();
              _elapsed = Duration.zero;
            }
            _bytes = 0;
            _totalBytes = 0;
            _speedBytesPerSec = 0;
            _lastBytes = 0;
            _lastSample = DateTime.now();
          } else if (_timerStarted) {
            // Live fetch detail between tracks (starting, retrying, adding).
            _phase = status;
          } else {
            _status = status;
          }
        });
      },
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _index = done;
            _count = total;
          });
        }
      },
      onBytes: _handleBytes,
    );
    if (mounted) navigator.pop();
    if (result != null && !result.cancelled && result.added >= 1) {
      if (navigator.mounted) {
        await _recommendRestart(navigator, result.added);
      }
    }
  }

  /// After a bulk import the Dart heap stays grown until the process restarts;
  /// offer that restart right away instead of letting the app carry the
  /// import's memory for the rest of the session.
  Future<void> _recommendRestart(NavigatorState navigator, int added) async {
    final restart = await showDialog<bool>(
      context: navigator.context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import complete'),
        content: Text(
          'Added $added ${added == 1 ? 'song' : 'songs'}. Restart the app now '
          'to release the memory used during the import, which keeps '
          'playback smooth.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restart now'),
          ),
        ],
      ),
    );
    if (restart == true) {
      await widget.controller.restartApp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: const Text('Importing library profile'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _count > 0 ? _index / _count : null),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _count > 0 ? '$_index of $_count tracks' : 'Reading profile…',
                style: small,
              ),
              const Spacer(),
              Text(
                _timerStarted ? 'elapsed ${_fmtDuration(_elapsed)}' : '',
                style: small,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(_detailLine, style: small),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: _totalBytes > 0
                ? (_bytes / _totalBytes).clamp(0.0, 1.0).toDouble()
                : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancelRequested
              ? null
              : () {
                  setState(() => _cancelRequested = true);
                  widget.controller.cancelLibraryProfileImport();
                },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
