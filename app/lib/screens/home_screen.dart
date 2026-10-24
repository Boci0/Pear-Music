import '../widgets/pear_sheet.dart';
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
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/filter_pill.dart';
import '../widgets/import_export_sheet.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/pear_popup.dart';
import '../widgets/song_tile.dart';
import '../widgets/tactile_button.dart';
import '../widgets/glow_room.dart';
import '../widgets/pear_empty_state.dart';
import '../widgets/pear_page_route.dart';
import 'explore_screen.dart';
import 'home_feed_screen.dart';
import 'home_shell.dart';
import 'playlists_screen.dart';

/// Library tab: drag & drop (Windows) or picker, then play.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static final ValueNotifier<String> _searchRequests = ValueNotifier('');

  /// Fills the library search with [query], as typing it does. The wide
  /// rail's search field calls this, then switches to this tab.
  static void requestSearch(String query) {
    // Cleared first so asking for the same query twice still notifies.
    _searchRequests.value = '';
    _searchRequests.value = query;
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  /// Wait after the last keystroke before the query reaches the list. Filtering
  /// and sorting the whole library is not worth doing for every character, and
  /// the list stays one frame behind the caret for at most this long.
  static const Duration _searchDebounceDelay = Duration(milliseconds: 180);

  bool _isSelecting = false;

  /// Which chip is on.
  _LibraryView _view = _LibraryView.all;
  String _searchQuery = '';
  Timer? _searchDebounce;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final Set<String> _selectedIds = {};
  int? _lastClickedIndex;

  /// Whether the on-screen keyboard is up. Read from the window: the shell's
  /// Scaffold has already taken the keyboard out of this tab's MediaQuery.
  bool _keyboardUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomeScreen._searchRequests.addListener(_onSearchRequest);
  }

  void _onSearchRequest() {
    final query = HomeScreen._searchRequests.value.trim();
    if (query.isEmpty || !mounted) return;
    _cancelSearchDebounce();
    _searchController.text = query;
    setState(() => _searchQuery = query);
  }

  @override
  void didChangeMetrics() {
    final up = View.of(context).viewInsets.bottom > 0;
    if (up != _keyboardUp) setState(() => _keyboardUp = up);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HomeScreen._searchRequests.removeListener(_onSearchRequest);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Applies a typed query after a short pause. Clearing the field is applied
  /// at once so the list never looks stuck behind an empty box.
  void _onSearchQueryChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      _searchDebounce = null;
      setState(() => _searchQuery = value);
      return;
    }
    _searchDebounce = Timer(_searchDebounceDelay, () {
      if (!mounted) return;
      setState(() => _searchQuery = value);
    });
  }

  /// Drops a pending debounce before the query is cleared another way, so the
  /// old text cannot land back in the list after the field is empty.
  void _cancelSearchDebounce() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
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

  /// Shift+click: extend the selection from the last clicked row to [index],
  /// like a desktop file list.
  void _selectRangeTo(List<Song> songs, int index) {
    final anchor = _lastClickedIndex;
    setState(() {
      _isSelecting = true;
      if (anchor == null || anchor >= songs.length) {
        _selectedIds.add(songs[index].id);
        return;
      }
      final start = min(anchor, index);
      final end = max(anchor, index);
      for (var i = start; i <= end; i++) {
        _selectedIds.add(songs[i].id);
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
      builder: (ctx) => PearAlertDialog(
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
    final playlist = await showPearPopup<Playlist>(
      context: context,
      showDragHandle: true,
      maxWidth: 400,
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
      final added = await _addAllToPlaylist(controller, playlist.id, selectedSongs);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _addedMessage(added, selectedSongs.length, playlist.name),
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

  /// Adds [songs] through the controller, which also remembers online
  /// songs (a playlist holds only ids, so an online song it cannot look up
  /// later drops out of it). Returns how many were new to the playlist.
  Future<int> _addAllToPlaylist(
    AppController controller,
    String playlistId,
    List<Song> songs,
  ) async {
    var added = 0;
    for (final song in songs) {
      if (await controller.addSongToPlaylist(playlistId, song.id, song: song)) {
        added++;
      }
    }
    return added;
  }

  static String _addedMessage(int added, int selected, String playlist) {
    String songs(int n) => n == 1 ? '1 song' : '$n songs';
    if (added == selected) return 'Added ${songs(added)} to $playlist';
    if (added == 0) {
      return selected == 1
          ? 'Already in $playlist'
          : 'All ${songs(selected)} are already in $playlist';
    }
    return 'Added ${songs(added)} to $playlist '
        '(${selected - added} already there)';
  }

  Future<void> _showCreatePlaylistDialog(
    AppController controller,
    List<Song> selectedSongs,
  ) async {
    final nameController = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => PearAlertDialog(
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
        final added = await _addAllToPlaylist(controller, p.id, selectedSongs);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_addedMessage(added, selectedSongs.length, p.name)),
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

  /// One library row, shared by the single and multi-column lists. The
  /// [index] comes from the list builders; looking it up with
  /// `songs.indexOf` would scan the whole library once per visible row.
  Widget _tileFor(
    Song song,
    int index,
    List<Song> songs,
    String? currentSongId, {
    required String sourceId,
    required String sourceTitle,
  }) {
    return RepaintBoundary(
      // The row's identity has to sit on the widget the list builds, or the
      // list's findChildIndexCallback never sees a key.
      key: ValueKey(song.id),
      child: SongTile(
        number: index + 1,
        song: song,
        queue: songs,
        sourceId: sourceId,
        sourceTitle: sourceTitle,
        isCurrent: currentSongId == song.id,
        isSelecting: _isSelecting,
        isSelected: _selectedIds.contains(song.id),
        onSelectionChanged: (val) {
          _lastClickedIndex = index;
          _toggleSelection(song.id, val ?? false);
        },
        onLongPress: () {
          _lastClickedIndex = index;
          setState(() {
            _isSelecting = true;
            _selectedIds.add(song.id);
          });
        },
        onCtrlTap: () {
          _lastClickedIndex = index;
          setState(() {
            _isSelecting = true;
            _selectedIds.add(song.id);
          });
        },
        onShiftTap: () => _selectRangeTo(songs, index),
        metaSuffix: song.sizeLabel,
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
            itemExtent: PearRow.extent,
            itemCount: songs.length,
            findChildIndexCallback: findIndex,
            itemBuilder: (context, i) => _tileFor(
              songs[i],
              i,
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
            mainAxisExtent: PearRow.extent,
            crossAxisSpacing: 10,
          ),
          itemCount: songs.length,
          findChildIndexCallback: findIndex,
          itemBuilder: (context, i) => _tileFor(
            songs[i],
            i,
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
  Widget _buildLibrarySearchField({
    required bool autofocus,
    String hint = 'Search library...',
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autofocus: autofocus,
        style: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
          ),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    _cancelSearchDebounce();
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
            borderRadius: BorderRadius.circular(PearGlassTokens.r(14)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(PearGlassTokens.r(14)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(PearGlassTokens.r(14)),
            borderSide: BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
        ),
        onChanged: _onSearchQueryChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    // Same cut as the shell's sideways dock.
    final tall = MediaQuery.sizeOf(context).height >= 500;
    List<Song> rawSongs = controller.songs;

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      rawSongs = rawSongs
          .where((s) => s.lowerTitle.contains(q) || s.lowerArtist.contains(q))
          .toList();
    }

    final songs = controller.getSortedSongs(rawSongs);
    final theme = Theme.of(context);
    final currentSongId = controller.player.currentSong?.id;

    final Widget content = _libraryList(controller, songs, currentSongId);

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
    if (_isSelecting) {
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
      // The search field sits in the list, always in view; Add music is the
      // floating button.
      headerContent = PearTabTitle(
        'Library',
        tag: '${songs.length} TRACKS',
        key: const ValueKey('header_default'),
      );
      headerActions = [
        // A phone held sideways has no height to spare for the floating
        // button, so Add music moves up here.
        if (!tall)
          TactileIconButton(
            tooltip: 'Add music',
            icon: const Icon(Icons.add),
            onPressed: () => controller.addFilesFromPicker(),
          ),
        Builder(
          builder: (buttonContext) => TactileIconButton(
            tooltip: 'Import & export',
            icon: const Icon(Icons.swap_vert_rounded),
            onPressed: () => _openImportExport(buttonContext, controller),
          ),
        ),
      ];
    }

    return CallbackShortcuts(
      bindings: {
        // Desktop conveniences: Ctrl+F focuses the library search field and
        // Escape backs out of search or selection, like a native window.
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          _searchFocusNode.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () {
          if (songs.isEmpty) return;
          if (_isSelecting && _selectedIds.length == songs.length) return;
          setState(() {
            _isSelecting = true;
            _selectedIds
              ..clear()
              ..addAll(songs.map((s) => s.id));
          });
        },
        const SingleActivator(LogicalKeyboardKey.delete): () {
          // Text fields consume Delete themselves before this handler runs;
          // the guard is belt and braces for exotic focus states.
          if (_searchFocusNode.hasFocus) return;
          if (_isSelecting && _selectedIds.isNotEmpty) {
            _batchDelete(controller, songs);
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_isSelecting) {
            setState(() {
              _isSelecting = false;
              _selectedIds.clear();
            });
          } else if (_searchQuery.isNotEmpty) {
            _cancelSearchDebounce();
            setState(() {
              _searchQuery = '';
              _searchController.clear();
            });
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
        // Hidden while typing so it does not sit over the search results.
        floatingActionButton: !_isSelecting && tall && !_keyboardUp
            ? Padding(
                // The shell's dock overlays this tab; lift the button over it.
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
                child: FloatingActionButton.extended(
                  key: const ValueKey('add_music'),
                  onPressed: () => controller.addFilesFromPicker(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add music'),
                ),
              )
            : null,
      ),
    );
  }

  /// The search field, chips for All, Playlists, Downloads and
  /// History, and the rows the chip picks. A query filters playlists and
  /// songs here first and offers the same search online in Explore.
  ///
  /// shortcut: no offline mark per row, every library song is already a file
  /// on this device; add one when songs can be kept online only.
  Widget _libraryList(
    AppController controller,
    List<Song> songs,
    String? currentSongId,
  ) {
    final theme = Theme.of(context);
    final query = _searchQuery.trim();
    final lower = query.toLowerCase();
    final showPlaylists =
        _view == _LibraryView.all || _view == _LibraryView.playlists;
    final showSongs =
        _view == _LibraryView.all || _view == _LibraryView.downloads;
    final playlists = [
      for (final p in controller.playlists)
        if (p.name.toLowerCase().contains(lower)) p,
    ];
    final history = _view != _LibraryView.history
        ? const <Song>[]
        : [
            for (final s in controller.historySongs)
              if (s.lowerTitle.contains(lower) ||
                  s.lowerArtist.contains(lower))
                s,
          ];
    // Room for the Add music button above the dock at the end of the list.
    final listEnd = EdgeInsets.only(
      // Sideways the landscape rail has no dock to clear and no button here.
      bottom: MediaQuery.sizeOf(context).height < 500 ? 16 : 210,
    );

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // Sideways there is no height for two rows: search and chips share one.
        if (MediaQuery.sizeOf(context).height < 500)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 0, 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 280,
                    child: _buildLibrarySearchField(
                      autofocus: false,
                      hint: 'Search your music or online',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(right: 16),
                      child: Row(
                        children: [
                          for (final v in _LibraryView.values) ...[
                            FilterPill(
                              key: ValueKey('chip_${v.name}'),
                              label: v.label,
                              isSelected: _view == v,
                              onTap: () => setState(() => _view = v),
                            ),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _buildLibrarySearchField(
              autofocus: false,
              hint: 'Search your music or online',
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: GlowRoom(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  for (final v in _LibraryView.values) ...[
                    FilterPill(
                      key: ValueKey('chip_${v.name}'),
                      label: v.label,
                      isSelected: _view == v,
                      onTap: () => setState(() => _view = v),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
        ),
        ],
        const SliverToBoxAdapter(child: PearSpecRule()),
        if (query.isNotEmpty)
          SliverToBoxAdapter(
            child: ListTile(
              key: const ValueKey('search_online'),
              leading: const Icon(Icons.travel_explore_rounded),
              title: Text('Search online for "$query"'),
              onTap: () {
                ExploreScreen.requestSearch(query);
                HomeShell.requestTab(2);
              },
            ),
          ),
        if (showPlaylists)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            sliver: SliverList.list(
              children: [
                if (query.isEmpty)
                  SizedBox(
                    height: 72,
                    child: PlaylistsScreen.newPlaylistTile(context, controller),
                  ),
                if ('liked songs'.contains(lower))
                  ListTile(
                    key: const ValueKey('library_liked'),
                    leading: Icon(
                      Icons.favorite_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    title: const Text('Liked songs'),
                    subtitle: Text('${controller.favoriteSongs.length} songs'),
                    onTap: () => Navigator.of(
                      context,
                    ).push(PearPageRoute(builder: (_) => const LikedPage())),
                  ),
                for (final p in playlists)
                  SizedBox(
                    height: 72,
                    child: PlaylistsScreen.playlistTile(context, controller, p),
                  ),
              ],
            ),
          ),
        if (showSongs) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${songs.length} songs',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Builder(
                    builder: (sortContext) => FilterPill(
                      key: const ValueKey('pill_sort'),
                      icon: Icons.sort_rounded,
                      label: 'Sort: ${_sortLabel(controller.sortOption)}',
                      isSelected: false,
                      onTap: () => showLibrarySortSheet(
                        context,
                        controller,
                        anchor: popupAnchorBelowLeft(sortContext),
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
              child: query.isEmpty
                  ? _EmptyState(onAdd: () => controller.addFilesFromPicker())
                  : PearEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Nothing in your library matches',
                    message:
                        'Check the spelling, or search online when you are connected.',
                    actionLabel: 'Search online',
                    onAction: () {
                      ExploreScreen.requestSearch(query);
                      HomeShell.requestTab(2);
                    },
                  ),
            )
          else
            SliverPadding(
              padding: listEnd,
              sliver: _songsSliver(
                songs,
                currentSongId,
                sourceId: 'library',
                sourceTitle: 'Library',
              ),
            ),
        ],
        if (_view == _LibraryView.history)
          if (history.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: PearEmptyState(
                icon: Icons.history_rounded,
                title: 'Nothing played yet',
                message: 'Songs you play show up here, newest first.',
              ),
            )
          else
            SliverPadding(
              padding: listEnd,
              sliver: SliverFixedExtentList.builder(
                itemExtent: PearRow.extent,
                itemCount: history.length,
                itemBuilder: (context, i) => SongTile(
                  key: ValueKey('history_${history[i].id}'),
                  song: history[i],
                  queue: history,
                  sourceId: 'history',
                  sourceTitle: 'History',
                  isCurrent: history[i].id == currentSongId,
                ),
              ),
            ),
        if (_view == _LibraryView.playlists)
          const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }
}

/// The Library's chips.
enum _LibraryView {
  all('All'),
  playlists('Playlists'),
  downloads('Downloads'),
  history('History');

  const _LibraryView(this.label);
  final String label;
}

void showLibrarySortSheet(
  BuildContext context,
  AppController controller, {
  Offset? anchor,
}) {
  showPearPopup<void>(
    context: context,
    showDragHandle: true,
    maxWidth: 360,
    anchor: anchor,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PearSheetTitle('SORT LIBRARY'),
          for (final (option, label) in [
            (SortOption.dateAdded, 'Date added'),
            (SortOption.size, 'File size'),
            (SortOption.title, 'Title (A-Z)'),
          ])
            PearSheetRow(
              label: label,
              selected: controller.sortOption == option,
              icon: controller.sortOption == option
                  ? Icons.check_rounded
                  : null,
              onTap: () {
                TactileFeedback.selection();
                controller.setSortOption(option);
                Navigator.pop(ctx);
              },
            ),
          const SizedBox(height: 8),
        ],
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
    return PearEmptyState(
      icon: Icons.library_music_rounded,
      title: 'Your music library is empty',
      message: 'Add audio files from this device to fill it.',
      actionLabel: 'Add music',
      onAction: onAdd,
    );
  }
}

/// Opens the import & export sheet and runs whatever the user picks.
Future<void> _openImportExport(
  BuildContext context,
  AppController controller,
) async {
  final action = await showImportExportSheet(
    context,
    controller,
    anchor: popupAnchorBelowRight(context),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case ImportExportAction.exportLibrary:
      await controller.exportLibraryProfile();
    case ImportExportAction.importLibrary:
      await _showLibraryProfileImportDialog(context, controller);
    case ImportExportAction.importPlaylists:
      await showPlaylistImportDialog(context, controller);
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
  String _status = 'Choosing a backup file…';
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
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final hours = d.inHours;
    if (hours > 0) {
      final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '${d.inMinutes}:$seconds';
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
      builder: (dialogContext) => PearAlertDialog(
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
    return PearAlertDialog(
      title: const Text('Restoring library backup'),
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
                _count > 0 ? '$_index of $_count tracks' : 'Reading backup…',
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
