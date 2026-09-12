import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../services/identity_service.dart';
import '../../services/player_service.dart';
import '../../services/stream_cache_manager.dart';

/// Top bar button displaying a simple info icon next to the sleep timer.
class StreamQualityInfoButton extends StatelessWidget {
  const StreamQualityInfoButton({super.key, required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Track Info',
      icon: const Icon(Icons.info_outline_rounded),
      onPressed: () => StreamQualityInfoDialog.show(context),
    );
  }
}

/// Read-only information pane displaying audio stream diagnostics, track file
/// metadata, cache details, and network policies.
class StreamQualityInfoDialog extends StatefulWidget {
  const StreamQualityInfoDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (ctx) => const RepaintBoundary(
        child: StreamQualityInfoDialog(),
      ),
    );
  }

  @override
  State<StreamQualityInfoDialog> createState() => _StreamQualityInfoDialogState();
}

class _StreamQualityInfoDialogState extends State<StreamQualityInfoDialog> {
  bool _canOpen = false;
  String? _lastCheckedPath;

  @override
  void initState() {
    super.initState();
    _initFileMetadata();
  }

  Future<void> _initFileMetadata() async {
    final player = context.read<PlayerService>();
    final file = await player.resolveCurrentLoadedFile();
    if (mounted && file != null) {
      _checkCanOpen(file.path);
      setState(() {});
    }
  }

  void _checkCanOpen(String? path) {
    if (path == _lastCheckedPath) return;
    _lastCheckedPath = path;
    if (path == null || path.isEmpty) {
      _canOpen = false;
      return;
    }
    _canOpen = (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
        File(path).existsSync();
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatAudioCodecAndContainer(String? format, String? path) {
    final ext = (format ?? (path != null ? p.extension(path).replaceFirst('.', '') : '')).toLowerCase();
    switch (ext) {
      case 'webm':
        return 'Opus (WebM container)';
      case 'm4a':
        return 'AAC (M4A container)';
      case 'opus':
        return 'Opus (Ogg container)';
      case 'mp3':
        return 'MP3';
      case 'flac':
        return 'FLAC (Lossless)';
      case 'ogg':
        return 'Ogg Vorbis / Opus';
      case 'wav':
        return 'WAV (PCM)';
      default:
        return ext.isNotEmpty ? ext.toUpperCase() : 'Unknown';
    }
  }

  Future<void> _openFileLocation(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', filePath]);
      } else if (Platform.isLinux) {
        final dir = File(filePath).parent.path;
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  Future<void> _copyToClipboard(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Path copied to clipboard'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final currentSong = context.select<PlayerService, Song?>((p) => p.currentSong);
    final identity = context.watch<IdentityService?>();
    final activeQuality = identity?.streamingQuality ?? StreamCacheManager.currentQuality;
    final isStream = currentSong?.sourceDeviceId == 'stream';

    final loadedQuality = context.select<PlayerService, StreamingQuality?>((p) => p.currentLoadedQuality);
    final loadedFile = context.select<PlayerService, File?>((p) => p.currentLoadedFile);
    final loadedSize = context.select<PlayerService, int?>((p) => p.currentLoadedFileSize);
    final loadedFormat = context.select<PlayerService, String?>((p) => p.currentLoadedFormat);

    final filePath = loadedFile?.path ??
        (currentSong != null && !isStream ? player.library.songFile(currentSong).path : null);
    final copyTarget = filePath ?? (currentSong?.id ?? '');
    _checkCanOpen(filePath);

    return RepaintBoundary(
      child: Material(
        color: const Color(0xFF0D0D0D),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom +
                MediaQuery.paddingOf(context).bottom +
                12,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF333333),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Info',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),

                // Quick actions: Copy Path & Open Location
                if (copyTarget.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: const Color(0xFF1E1E1E),
                            side: const BorderSide(color: Color(0xFF333333)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.content_copy_rounded, size: 14, color: Colors.white70),
                          label: const Text(
                            'Copy path',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                          onPressed: () => _copyToClipboard(context, copyTarget),
                        ),
                        if (_canOpen && filePath != null)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: const Color(0xFF1E1E1E),
                              side: const BorderSide(color: Color(0xFF333333)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.folder_open_rounded, size: 14, color: Colors.white70),
                            label: const Text(
                              'Open location',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                            onPressed: () => _openFileLocation(filePath),
                          ),
                      ],
                    ),
                  ),

                const SizedBox(height: 8),

                // Section 1: Track & File Properties
                _buildSectionHeader('TRACK & FILE PROPERTIES'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF262626)),
                    ),
                    child: currentSong == null
                        ? const Text(
                            'No track currently loaded.',
                            style: TextStyle(color: Color(0xFF888888), fontSize: 12),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentSong.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13.5,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              if (filePath != null)
                                _buildPropertyRow(
                                  'File Name',
                                  p.basename(filePath),
                                ),
                              _buildPropertyRow(
                                'Location',
                                filePath ?? 'Streaming memory buffer',
                              ),
                              if (loadedSize != null || currentSong.size > 0)
                                _buildPropertyRow(
                                  'File Size',
                                  _formatBytes(loadedSize ?? currentSong.size),
                                ),
                              _buildPropertyRow(
                                'Duration',
                                player.duration != null
                                    ? _formatDuration(player.duration!)
                                    : '--:--',
                              ),
                              if (loadedFormat != null || (filePath != null && p.extension(filePath).isNotEmpty))
                                _buildPropertyRow(
                                  'Audio Format',
                                  _formatAudioCodecAndContainer(loadedFormat, filePath),
                                ),
                            ],
                          ),
                  ),
                ),

                const SizedBox(height: 12),

                // Section 2: Stream & Resolver Diagnostics
                _buildSectionHeader('STREAM & RESOLVER DIAGNOSTICS'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF262626)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildPropertyRow(
                          'Source Route',
                          isStream
                              ? (player.currentRouteType == StreamRouteType.cached
                                  ? 'Local Disk Cache (0ms hit)'
                                  : 'Live Stream via yt-dlp')
                              : 'Local Music Library',
                        ),
                        _buildPropertyRow(
                          'Active Setting',
                          '${activeQuality.label} (${activeQuality.subtitle})',
                        ),
                        if (isStream) ...[
                          _buildPropertyRow(
                            'Loaded Quality',
                            loadedQuality != null
                                ? loadedQuality.label
                                : (loadedFile != null ? 'Legacy Cache' : 'Resolving...'),
                          ),
                          _buildPropertyRow(
                            'Resolver Rule',
                            StreamCacheManager.getAudioFormatArg(quality: activeQuality),
                          ),
                          _buildPropertyRow(
                            'Load Latency',
                            player.lastTrackLoadMs > 0
                                ? '${player.lastTrackLoadMs} ms'
                                : 'Instant (0 ms)',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF888888),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _buildPropertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 135,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF9E9E9E),
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
