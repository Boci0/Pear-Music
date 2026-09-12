import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/debug_log.dart';
import '../../services/session_diagnostics.dart';
import '../../services/stream_cache_manager.dart';

/// Interactive live terminal diagnostics console for real-time stream inspection.
class PlayerConsoleDialog extends StatefulWidget {
  const PlayerConsoleDialog({super.key});

  static Future<void> show(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 800;
    if (isWide) {
      return showDialog<void>(
        context: context,
        builder: (ctx) => const Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          child: PlayerConsoleDialog(),
        ),
      );
    } else {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => const FractionallySizedBox(
          heightFactor: 0.78,
          child: PlayerConsoleDialog(),
        ),
      );
    }
  }

  @override
  State<PlayerConsoleDialog> createState() => _PlayerConsoleDialogState();
}

class _ConsoleStatsData {
  final double rssMb;
  final double peakRssMb;
  final bool isPss;
  final int cacheTrackCount;
  final double cacheMb;
  final int inFlightCount;
  final String uptimeStr;
  final String lifecycleStr;
  final String playbackStr;
  final String batterySummary;
  final bool isCharging;

  const _ConsoleStatsData({
    this.rssMb = 0.0,
    this.peakRssMb = 0.0,
    this.isPss = false,
    this.cacheTrackCount = 0,
    this.cacheMb = 0.0,
    this.inFlightCount = 0,
    this.uptimeStr = '',
    this.lifecycleStr = '',
    this.playbackStr = '',
    this.batterySummary = 'Checking...',
    this.isCharging = false,
  });
}

class _PlayerConsoleDialogState extends State<PlayerConsoleDialog> {
  final List<String> _logs = [];
  final List<String> _pendingLogs = [];
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<_ConsoleStatsData> _statsNotifier =
      ValueNotifier<_ConsoleStatsData>(const _ConsoleStatsData());

  StreamSubscription<String>? _sub;
  Timer? _statsTimer;
  Timer? _logFlushTimer;
  bool _autoScroll = true;

  void _updateStats() async {
    if (!mounted) return;
    double rss = 0;
    bool isPss = false;
    try {
      if (!kIsWeb) {
        final pss = await SessionDiagnostics.getNativePssMb();
        if (pss != null && pss > 0) {
          rss = pss;
          isPss = true;
        } else {
          rss = ProcessInfo.currentRss / (1024 * 1024);
        }
      }
    } catch (_) {}
    SessionDiagnostics.recordRss(rss);
    await SessionDiagnostics.updateBatterySnapshot();
    if (!mounted) return;

    final stats = StreamCacheManager.getCacheStats();
    final uptime = SessionDiagnostics.sessionUptime;
    final fg = SessionDiagnostics.foregroundDuration;
    final bg = SessionDiagnostics.backgroundDuration;
    final playback = SessionDiagnostics.totalPlaybackDuration;
    final latestBattery = SessionDiagnostics.latestBattery;

    _statsNotifier.value = _ConsoleStatsData(
      rssMb: rss,
      isPss: isPss,
      peakRssMb: SessionDiagnostics.peakRssMb,
      cacheTrackCount: stats.trackCount,
      cacheMb: stats.totalBytes / (1024 * 1024),
      inFlightCount: stats.inFlightCount,
      uptimeStr: SessionDiagnostics.formatDuration(uptime),
      lifecycleStr:
          'FG: ${SessionDiagnostics.formatDuration(fg)} | BG: ${SessionDiagnostics.formatDuration(bg)}',
      playbackStr: SessionDiagnostics.formatDuration(playback),
      batterySummary: SessionDiagnostics.getBatterySummary(),
      isCharging: latestBattery?.isCharging ?? false,
    );
  }

  void _flushPendingLogs() {
    if (!mounted || _pendingLogs.isEmpty) return;
    setState(() {
      _logs.addAll(_pendingLogs);
      _pendingLogs.clear();
      if (_logs.length > 200) {
        _logs.removeRange(0, _logs.length - 200);
      }
    });
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _logs.addAll(DebugLog.recentLogs);
    _updateStats();
    _statsTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (_) => _updateStats());
    _logFlushTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _flushPendingLogs());

    _sub = DebugLog.stream.listen((line) {
      if (!mounted) return;
      _pendingLogs.add(line);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _logFlushTimer?.cancel();
    _sub?.cancel();
    _scrollController.dispose();
    _statsNotifier.dispose();
    super.dispose();
  }

  Color _getTagColor(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('[cache]')) return const Color(0xFF81C784); // Green
    if (lower.contains('[stream]')) return const Color(0xFF64B5F6); // Blue
    if (lower.contains('[preload]')) return const Color(0xFFBA68C8); // Purple
    if (lower.contains('[fallback]')) return const Color(0xFFFFB74D); // Orange
    if (lower.contains('[radio]')) return const Color(0xFFFFD54F); // Yellow
    if (lower.contains('[player]')) return const Color(0xFF4DD0E1); // Cyan
    return const Color(0xFFE0E0E0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0C0C0C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black87,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.terminal_rounded,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
                Expanded(
                  child: Text(
                    'Diagnostics Console',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Consolas',
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: _autoScroll ? 'Auto-scroll: ON' : 'Auto-scroll: OFF',
                  icon: Icon(
                    _autoScroll ? Icons.vertical_align_bottom : Icons.pause_circle_outline,
                    color: _autoScroll ? scheme.primary : Colors.white38,
                  ),
                  onPressed: () => setState(() => _autoScroll = !_autoScroll),
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Copy logs',
                  icon: const Icon(Icons.copy_rounded, color: Colors.white70),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _logs.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Diagnostics logs copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Clear view',
                  icon: const Icon(Icons.delete_sweep_rounded, color: Colors.white70),
                  onPressed: () {
                    DebugLog.clearRecent();
                    setState(() => _logs.clear());
                  },
                ),
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          // Live Resource Usage Bar (Lightweight O(1) in-memory stats, zero emojis, isolated repaint)
          ValueListenableBuilder<_ConsoleStatsData>(
            valueListenable: _statsNotifier,
            builder: (context, stats, _) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 14,
                      runSpacing: 5,
                      children: [
                        _buildStatItem(
                          icon: stats.isCharging
                              ? Icons.battery_charging_full_rounded
                              : Icons.battery_std_rounded,
                          label: 'Battery: ${stats.batterySummary}',
                          color: stats.isCharging
                              ? const Color(0xFF81C784)
                              : const Color(0xFFFFD54F),
                        ),
                        _buildStatItem(
                          icon: Icons.timer_outlined,
                          label: 'Uptime: ${stats.uptimeStr} (${stats.lifecycleStr})',
                          color: const Color(0xFFE0E0E0),
                        ),
                        if (stats.playbackStr.isNotEmpty && stats.playbackStr != '0s')
                          _buildStatItem(
                            icon: Icons.music_note_rounded,
                            label: 'Playback: ${stats.playbackStr}',
                            color: const Color(0xFF4DD0E1),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 14,
                      runSpacing: 5,
                      children: [
                        _buildStatItem(
                          icon: Icons.memory_rounded,
                          label:
                              'RAM (${stats.isPss ? "PSS" : "RSS"}): ${stats.rssMb.toStringAsFixed(1)} MB (Peak: ${stats.peakRssMb.toStringAsFixed(1)} MB)',
                          color: const Color(0xFF81C784),
                        ),
                        _buildStatItem(
                          icon: Icons.storage_rounded,
                          label:
                              'Cache: ${stats.cacheTrackCount} tracks (${stats.cacheMb.toStringAsFixed(1)} MB)',
                          color: const Color(0xFF64B5F6),
                        ),
                        _buildStatItem(
                          icon: stats.inFlightCount > 0
                              ? Icons.downloading_rounded
                              : Icons.check_circle_outline_rounded,
                          label:
                              'Preload: ${stats.inFlightCount > 0 ? "Buffering ${stats.inFlightCount}" : "Idle"}',
                          color: stats.inFlightCount > 0
                              ? const Color(0xFFFFB74D)
                              : Colors.white60,
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          // Console Output Area
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        'No diagnostic logs captured yet.\nStart playing or skipping tracks to see live events.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                          fontFamily: 'Consolas',
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, idx) {
                        final line = _logs[idx];
                        final textColor = _getTagColor(line);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.5),
                          child: SelectableText(
                            line,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 11.5,
                              fontFamily: 'Consolas',
                              height: 1.35,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFamily: 'Consolas',
          ),
        ),
      ],
    );
  }
}
