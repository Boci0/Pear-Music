import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/identity_service.dart';
import '../services/youtube_service.dart';
import '../widgets/song_tile.dart';

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
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _searchController.dispose();
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
    final selectedSongs = songs.where((s) => _selectedIds.contains(s.id)).toList();
    final count = selectedSongs.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $count ${count == 1 ? "song" : "songs"}?'),
        content: const Text(
          'This deletes the selected songs from this device and removes them from '
          'any playlists.',
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
      for (final song in selectedSongs) {
        await controller.removeSong(song);
      }
      if (mounted) {
        setState(() {
          _isSelecting = false;
          _selectedIds.clear();
        });
      }
    }
  }

  Future<void> _batchAddToPlaylist(
      AppController controller, List<Song> songs) async {
    if (_selectedIds.isEmpty) return;
    final selectedSongs = songs.where((s) => _selectedIds.contains(s.id)).toList();
    final playlists = controller.library.playlists;
    final playlist = await showModalBottomSheet<Playlist>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Add ${selectedSongs.length} songs to playlist',
                  style: Theme.of(ctx).textTheme.titleMedium),
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
                'Added ${selectedSongs.length} songs to ${playlist.name}'),
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
      AppController controller, List<Song> selectedSongs) async {
    final nameController = TextEditingController();
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
            content:
                Text('Created "$name" with ${selectedSongs.length} songs')),
        );
        setState(() {
          _isSelecting = false;
          _selectedIds.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    List<Song> rawSongs =
        _showOnlyFavorites ? controller.favoriteSongs : controller.songs;

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
              sliver: SliverFixedExtentList.builder(
                itemExtent: 61.0,
                itemCount: songs.length,
                findChildIndexCallback: (Key key) {
                  final valueKey = key as ValueKey<String>?;
                  if (valueKey == null) return null;
                  final index = songs.indexWhere((s) => s.id == valueKey.value);
                  return index >= 0 ? index : null;
                },
                itemBuilder: (context, i) {
                  final song = songs[i];
                  return RepaintBoundary(
                    child: SongTile(
                      key: ValueKey(song.id),
                      song: song,
                      queue: songs,
                      sourceId: 'search',
                      sourceTitle: 'Search',
                      isCurrent: currentSongId == song.id,
                      isSelecting: _isSelecting,
                      isSelected: _selectedIds.contains(song.id),
                      onSelectionChanged: (val) =>
                          _toggleSelection(song.id, val ?? false),
                      onLongPress: () {
                        setState(() {
                          _isSelecting = true;
                          _selectedIds.add(song.id);
                        });
                      },
                    ),
                  );
                },
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
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: Row(
                children: [
                  _FilterPill(
                    label: 'All (${controller.songs.length})',
                    isSelected: !_showOnlyFavorites,
                    onTap: () => setState(() => _showOnlyFavorites = false),
                  ),
                  const SizedBox(width: 8),
                  _FilterPill(
                    icon: _showOnlyFavorites ? Icons.favorite : Icons.favorite_border,
                    label: 'Favorites (${controller.favoriteSongs.length})',
                    isSelected: _showOnlyFavorites,
                    onTap: () => setState(() => _showOnlyFavorites = true),
                  ),
                  const SizedBox(width: 8),
                  _FilterPill(
                    icon: Icons.sort_rounded,
                    label: _sortLabel(controller.sortOption),
                    isSelected: false,
                    onTap: () => _showSortSheet(context, controller),
                  ),
                  const SizedBox(width: 8),
                  _FilterPill(
                    icon: Icons.checklist_rounded,
                    label: _isSelecting ? 'Done' : 'Select',
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
                                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.25),
                                  width: 1,
                                ),
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
                                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverFixedExtentList.builder(
                itemExtent: 61.0,
                itemCount: songs.length,
                findChildIndexCallback: (Key key) {
                  final valueKey = key as ValueKey<String>?;
                  if (valueKey == null) return null;
                  final index = songs.indexWhere((s) => s.id == valueKey.value);
                  return index >= 0 ? index : null;
                },
                itemBuilder: (context, i) {
                  final song = songs[i];
                  return RepaintBoundary(
                    child: SongTile(
                      key: ValueKey(song.id),
                      song: song,
                      queue: songs,
                      sourceId: _showOnlyFavorites ? 'favorites' : 'library',
                      sourceTitle: _showOnlyFavorites ? 'Favorites' : 'Library',
                      isCurrent: currentSongId == song.id,
                      isSelecting: _isSelecting,
                      isSelected: _selectedIds.contains(song.id),
                      onSelectionChanged: (val) =>
                          _toggleSelection(song.id, val ?? false),
                      onLongPress: () {
                        setState(() {
                          _isSelecting = true;
                          _selectedIds.add(song.id);
                        });
                      },
                    ),
                  );
                },
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
    if (_isSearching) {
      headerContent = Row(
        key: const ValueKey('header_search'),
        children: [
          IconButton(
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
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search library...',
                  hintStyle: TextStyle(
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainer,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                  ),
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
          ),
        ],
      );
    } else if (_isSelecting) {
      headerContent = Row(
        key: const ValueKey('header_selecting'),
        children: [
          IconButton(
            tooltip: 'Cancel selection',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _isSelecting = false;
              _selectedIds.clear();
            }),
          ),
          const SizedBox(width: 8),
          Text(
            '${_selectedIds.length} selected',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            tooltip: _selectedIds.length == songs.length ? 'Deselect all' : 'Select all',
            icon: Icon(_selectedIds.length == songs.length ? Icons.deselect : Icons.select_all),
            onPressed: () => _selectAll(songs),
          ),
          IconButton(
            tooltip: 'Add to playlist',
            icon: const Icon(Icons.playlist_add),
            onPressed: _selectedIds.isEmpty ? null : () => _batchAddToPlaylist(controller, songs),
          ),
          IconButton(
            tooltip: 'Delete selected',
            icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            onPressed: _selectedIds.isEmpty ? null : () => _batchDelete(controller, songs),
          ),
        ],
      );
    } else {
      headerContent = Row(
        key: const ValueKey('header_default'),
        children: [
          Image.asset(
            'assets/pear_logo.png',
            width: 28,
            height: 28,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 8),
          const Text(
            'Library',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Search library',
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => _isSearching = true),
          ),
          PopupMenuButton<String>(
            tooltip: 'Add songs',
            icon: const Icon(Icons.add),
            onSelected: (val) async {
              if (val == 'local') {
                controller.addFilesFromPicker();
              } else if (val == 'link') {
                _openYouTubeDialog(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'local',
                child: Row(
                  children: [
                    Icon(Icons.folder_open, size: 20),
                    SizedBox(width: 12),
                    Text('Add local audio files'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'link',
                child: Row(
                  children: [
                    Icon(Icons.link, size: 20),
                    SizedBox(width: 12),
                    Text('Add from link (YouTube/Spotify)'),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 14,
        centerTitle: false,
        title: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: headerContent,
        ),
      ),
      body: body,
    );
  }
}

class _FilterPill extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_FilterPill> createState() => _FilterPillState();
}

class _FilterPillState extends State<_FilterPill> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    final double scale = _isPressed
        ? 0.93
        : (_isHovered ? 1.05 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isPressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? primary.withValues(alpha: _isHovered ? 0.28 : 0.20)
                  : (_isHovered
                      ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
                      : theme.colorScheme.surfaceContainer),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: widget.isSelected
                    ? primary.withValues(alpha: _isHovered ? 0.65 : 0.40)
                    : (_isHovered
                        ? Colors.white.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.07)),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: 14,
                    color: widget.isSelected
                        ? primary
                        : theme.colorScheme.onSurfaceVariant.withValues(alpha: _isHovered ? 1.0 : 0.8),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: widget.isSelected
                        ? primary
                        : theme.colorScheme.onSurfaceVariant.withValues(alpha: _isHovered ? 1.0 : 0.85),
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
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
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Sort Library',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.calendar_today_rounded,
                color: controller.sortOption == SortOption.dateAdded ? primary : null,
              ),
              title: const Text('Date Added'),
              trailing: controller.sortOption == SortOption.dateAdded
                  ? Icon(Icons.check_rounded, color: primary)
                  : null,
              onTap: () {
                controller.setSortOption(SortOption.dateAdded);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.sort_by_alpha_rounded,
                color: controller.sortOption == SortOption.title ? primary : null,
              ),
              title: const Text('Title (A-Z)'),
              trailing: controller.sortOption == SortOption.title
                  ? Icon(Icons.check_rounded, color: primary)
                  : null,
              onTap: () {
                controller.setSortOption(SortOption.title);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.data_usage_rounded,
                color: controller.sortOption == SortOption.size ? primary : null,
              ),
              title: const Text('File Size'),
              trailing: controller.sortOption == SortOption.size
                  ? Icon(Icons.check_rounded, color: primary)
                  : null,
              onTap: () {
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
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: primary.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.library_music_rounded,
                size: 38,
                color: primary,
              ),
            ),
            const SizedBox(height: 18),
            Text('Your music library is empty',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                )),
            const SizedBox(height: 8),
            Text(
              'Tap "Add music" to pick audio files.\nOn Windows you can also drag & drop files here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add music'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openYouTubeDialog(BuildContext context) async {
  final controller = context.read<AppController>();
  await showDialog<void>(
    context: context,
    builder: (_) => _YouTubeDialog(controller: controller),
  );
}

/// Paste a YouTube link, watch it download straight to this device, then let
/// the sync engine push it to paired peers.
class _YouTubeDialog extends StatefulWidget {
  final AppController controller;
  const _YouTubeDialog({required this.controller});

  @override
  State<_YouTubeDialog> createState() => _YouTubeDialogState();
}

class _YouTubeDialogState extends State<_YouTubeDialog> {
  final _urlController = TextEditingController();
  final _cancel = DownloadCancellation();
  bool _busy = false;
  String _status = '';
  String? _error;
  int _downloaded = 0;
  int _total = 0;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _start() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Starting…';
      _error = null;
      _downloaded = 0;
      _total = 0;
    });
    final error = await widget.controller.addFromLink(
      url,
      cancel: _cancel,
      onStatus: (s) {
        if (mounted) {
          setState(() => _status = s);
        }
      },
      onProgress: (downloaded, total) {
        // Throttle to ~12 updates/sec: every chunk (64KB) triggers this, and
        // rebuilding the dialog on each one is what made the progress bar lag
        // on the phone. Always show the final 100% state.
        final now = DateTime.now();
        final done = total > 0 && downloaded >= total;
        if (!done &&
            now.difference(_lastProgress).inMilliseconds < 80) {
          return;
        }
        _lastProgress = now;
        if (mounted) {
          setState(() {
            _downloaded = downloaded;
            _total = total;
          });
        }
      },
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      // Show the failure inline so the user can see why it stopped and retry.
      setState(() {
        _busy = false;
        _status = '';
        _error = error;
        _downloaded = 0;
        _total = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      // Everything (title, field, helper, progress, actions) lives inside a
      // SingleChildScrollView so the dialog can NEVER overflow: when the soft
      // keyboard shrinks the window in landscape, the content simply scrolls
      // instead of a RenderFlex overflowing. (AlertDialog's `scrollable` only
      // scrolls title + content, NOT the actions bar - which is the column
      // that overflowed on the phone by 23px.)
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Add from link',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                enabled: !_busy,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _start(),
                decoration: const InputDecoration(
                  labelText: 'YouTube or Spotify link',
                  hintText:
                      'https://www.youtube.com/watch?v=…  or  …/spotify.com/track/…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'YouTube links download the audio straight to this device. Spotify '
                'links are matched to their YouTube source (Spotify audio is '
                'DRM-protected), with full artwork metadata.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _total > 0
                        ? (_downloaded / _total).clamp(0.0, 1.0)
                        : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (_total > 0)
                      Text(
                        '${_bytes(_downloaded)} / ${_bytes(_total)} '
                        '(${(_downloaded / _total * 100).clamp(0, 100).toStringAsFixed(0)}%)',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              // Actions live INSIDE the scroll view too, so they can never be
              // pushed off-screen or overflow when vertical space is tight.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? () {
                            _cancel.cancel();
                            Navigator.of(context).pop();
                          }
                        : () => Navigator.of(context).pop(),
                    child: Text(_busy ? 'Cancel download' : 'Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _start,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
