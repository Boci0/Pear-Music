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
import '../services/youtube_search_service.dart';
import '../services/youtube_service.dart';
import '../widgets/about_dialog.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_song_tile.dart';
import 'playlists_screen.dart';

/// Categories for search filtering.
enum SearchFilter { all, library, youtube }

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
  SearchFilter _searchFilter = SearchFilter.all;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedIds = {};
  List<YouTubeSearchResult> _ytResults = [];
  bool _isSearchingYt = false;
  Timer? _ytSearchDebounce;

  @override
  void dispose() {
    _ytSearchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchQueryChanged(String v) {
    setState(() => _searchQuery = v);
    _ytSearchDebounce?.cancel();
    if (v.trim().length < 2) {
      setState(() {
        _ytResults = [];
        _isSearchingYt = false;
      });
      return;
    }
    if (_searchFilter == SearchFilter.library) return;
    setState(() => _isSearchingYt = true);
    _ytSearchDebounce = Timer(const Duration(milliseconds: 350), () async {
      final res = await YouTubeSearchService.search(v);
      if (mounted && _searchQuery == v) {
        setState(() {
          _ytResults = res;
          _isSearchingYt = false;
        });
      }
    });
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
    List<Song> rawSongs = controller.songs;

    if (_showOnlyFavorites && !_isSearching) {
      rawSongs = rawSongs.where((s) => controller.isFavorite(s.id)).toList();
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      rawSongs = rawSongs.where((s) => s.title.toLowerCase().contains(q)).toList();
    }

    final songs = controller.getSortedSongs(rawSongs);
    final theme = Theme.of(context);
    final currentSongId = controller.player.currentSong?.id;

    final Widget content;
    if (_isSearching) {
      content = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _searchFilter == SearchFilter.all,
                    onSelected: (_) {
                      setState(() => _searchFilter = SearchFilter.all);
                      _onSearchQueryChanged(_searchQuery);
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Library'),
                    selected: _searchFilter == SearchFilter.library,
                    onSelected: (_) => setState(() => _searchFilter = SearchFilter.library),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('YouTube'),
                    selected: _searchFilter == SearchFilter.youtube,
                    onSelected: (_) {
                      setState(() => _searchFilter = SearchFilter.youtube);
                      _onSearchQueryChanged(_searchQuery);
                    },
                  ),
                ],
              ),
            ),
          ),
          if (_searchFilter != SearchFilter.youtube) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'IN YOUR LIBRARY (${songs.length})',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            if (songs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'No local matches',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              )
            else
              SliverFixedExtentList.builder(
                itemExtent: 68.0,
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
          ],
          if (_searchFilter != SearchFilter.library) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  children: [
                    Text(
                      'YOUTUBE / ONLINE (${_ytResults.length})',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    if (_isSearchingYt) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_isSearchingYt && _ytResults.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (_ytResults.isEmpty && _searchQuery.trim().length >= 2)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'No online results found',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              )
            else if (_searchQuery.trim().length < 2)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'Type at least 2 characters to search YouTube',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: _ytResults.length,
                itemBuilder: (context, i) {
                  final result = _ytResults[i];
                  return YouTubeSongTile(
                    key: ValueKey(result.videoId),
                    result: result,
                    isCurrent: controller.player.currentSong?.title == result.title,
                  );
                },
              ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      );
    } else {
      content = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_showOnlyFavorites)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.favorite, size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Showing Favorites (${songs.length})',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        setState(() => _showOnlyFavorites = false);
                        if (controller.player.hasLoaded &&
                            (controller.player.queueSourceId == 'library' ||
                                controller.player.queueSourceId == 'favorites' ||
                                controller.player.queueSourceId == null)) {
                          final updatedQueue = controller.getSortedSongs(controller.songs);
                          controller.player.updateQueue(
                            updatedQueue,
                            sourceId: 'library',
                            sourceTitle: 'Library',
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          'Show all',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (songs.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(onAdd: () => controller.addFilesFromPicker()),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverFixedExtentList.builder(
                itemExtent: 68.0,
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

    final List<Widget> appBarActions;
    if (_isSearching) {
      appBarActions = [
        IconButton(
          tooltip: 'Clear search',
          icon: const Icon(Icons.close),
          onPressed: () {
            setState(() {
              _searchQuery = '';
              _ytResults = [];
              _isSearchingYt = false;
              _searchController.clear();
            });
          },
        ),
      ];
    } else if (_isSelecting) {
      appBarActions = [
        IconButton(
          tooltip: _selectedIds.length == songs.length
              ? 'Deselect all'
              : 'Select all',
          icon: Icon(_selectedIds.length == songs.length
              ? Icons.deselect
              : Icons.select_all),
          onPressed: () => _selectAll(songs),
        ),
        IconButton(
          tooltip: 'Add to playlist',
          icon: const Icon(Icons.playlist_add),
          onPressed: _selectedIds.isEmpty
              ? null
              : () => _batchAddToPlaylist(controller, songs),
        ),
        IconButton(
          tooltip: 'Delete selected',
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          onPressed: _selectedIds.isEmpty
              ? null
              : () => _batchDelete(controller, songs),
        ),
        const SizedBox(width: 4),
      ];
    } else {
      appBarActions = [
        IconButton(
          tooltip: 'Search library & YouTube',
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => _isSearching = true),
        ),
        PopupMenuButton<String>(
          tooltip: 'Add & Sync options',
          icon: const Icon(Icons.add),
          onSelected: (val) async {
            if (val == 'local') {
              controller.addFilesFromPicker();
            } else if (val == 'sync') {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Reconnecting & Syncing library...'),
                  duration: Duration(seconds: 2),
                ),
              );
              final count = await controller.forceSync();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      count > 0
                          ? 'Resynced with $count active peer(s)'
                          : 'Reconnected signaling; scanning for peers',
                    ),
                  ),
                );
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'local',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.folder_open),
                title: Text('Add local audio files'),
              ),
            ),
            PopupMenuItem(
              value: 'sync',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.sync),
                title: Text('Force sync files'),
              ),
            ),
          ],
        ),
        PopupMenuButton<String>(
          tooltip: 'More options',
          icon: const Icon(Icons.more_vert),
          onSelected: (val) async {
            if (val == 'fav_toggle') {
              final newFavState = !_showOnlyFavorites;
              setState(() => _showOnlyFavorites = newFavState);
              if (controller.player.hasLoaded &&
                  (controller.player.queueSourceId == 'library' ||
                      controller.player.queueSourceId == 'favorites' ||
                      controller.player.queueSourceId == null)) {
                var currentList = controller.songs;
                if (newFavState && !_isSearching) {
                  currentList = currentList.where((s) => controller.isFavorite(s.id)).toList();
                }
                final updatedQueue = controller.getSortedSongs(currentList);
                controller.player.updateQueue(
                  updatedQueue,
                  sourceId: newFavState ? 'favorites' : 'library',
                  sourceTitle: newFavState ? 'Favorites' : 'Library',
                );
              }
            } else if (val == 'sort_date') {
              await controller.setSortOption(SortOption.dateAdded);
            } else if (val == 'sort_title') {
              await controller.setSortOption(SortOption.title);
            } else if (val == 'sort_size') {
              await controller.setSortOption(SortOption.size);
            } else if (val == 'select') {
              setState(() => _isSelecting = true);
            } else if (val == 'playlists') {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
              );
            } else if (val == 'about') {
              showPearMusicAboutDialog(context);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'fav_toggle',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _showOnlyFavorites ? Icons.favorite : Icons.favorite_border,
                  color: _showOnlyFavorites ? theme.colorScheme.primary : null,
                ),
                title: Text(_showOnlyFavorites ? 'Show all songs' : 'Show favorites only'),
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'sort_date',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  controller.sortOption == SortOption.dateAdded
                      ? Icons.check
                      : Icons.calendar_today,
                  size: 20,
                ),
                title: const Text('Sort: Date Added'),
              ),
            ),
            PopupMenuItem(
              value: 'sort_title',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  controller.sortOption == SortOption.title
                      ? Icons.check
                      : Icons.sort_by_alpha,
                  size: 20,
                ),
                title: const Text('Sort: Title'),
              ),
            ),
            PopupMenuItem(
              value: 'sort_size',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  controller.sortOption == SortOption.size
                      ? Icons.check
                      : Icons.data_usage,
                  size: 20,
                ),
                title: const Text('Sort: File Size'),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'select',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.checklist),
                title: Text('Select multiple songs'),
              ),
            ),
            if (!_isDesktop && MediaQuery.sizeOf(context).width < 850) ...[
              const PopupMenuItem(
                value: 'playlists',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.queue_music),
                  title: Text('Playlists'),
                ),
              ),
              const PopupMenuItem(
                value: 'about',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.info_outline),
                  title: Text('About & License'),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(width: 4),
      ];
    }

    Widget? leading;
    Widget title;

    if (_isSearching) {
      leading = IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          setState(() {
            _isSearching = false;
            _searchQuery = '';
            _ytResults = [];
            _isSearchingYt = false;
            _searchController.clear();
          });
        },
      );
      title = TextField(
        controller: _searchController,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search songs, artists, or YouTube...',
          border: InputBorder.none,
        ),
        onChanged: _onSearchQueryChanged,
      );
    } else if (_isSelecting) {
      leading = IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(() {
          _isSelecting = false;
          _selectedIds.clear();
        }),
      );
      title = Text('${_selectedIds.length} selected');
    } else {
      leading = null;
      title = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/pear_logo.png',
            width: 28,
            height: 28,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 8),
          const Text('Library'),
          const SizedBox(width: 8),
          _ConnectionDot(
            status: controller.connectionStatus,
            hosting: controller.isHostingServer,
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: leading,
        title: title,
        actions: appBarActions,
      ),
      body: body,
    );
  }
}



/// Compact connection indicator for narrow/mobile app bars (a plain colored
/// dot instead of a full chip, so the title is never squeezed out).
class _ConnectionDot extends StatelessWidget {
  final String status;
  final bool hosting;
  const _ConnectionDot({required this.status, required this.hosting});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'connected' => hosting ? Colors.teal : Colors.green,
      'connecting' => Colors.orange,
      _ => Colors.grey,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music_outlined,
                size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Your music library is empty',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tap "Add music" to pick audio files.\nOn Windows you can also drag & drop files here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
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
                'DRM-protected), so either way it syncs to your paired devices '
                'with artwork.',
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
