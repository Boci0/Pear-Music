import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Compact, draggable on-screen overlay showing live FPS, frame time, process
/// resident memory (RSS / peak), and Flutter image cache usage.
class ResourceOverlay extends StatefulWidget {
  const ResourceOverlay({super.key});

  @override
  State<ResourceOverlay> createState() => _ResourceOverlayState();
}

class _ResourceOverlayState extends State<ResourceOverlay> {
  static const Duration _window = Duration(seconds: 1);
  static const double _pillWidth = 176;
  static const double _pillHeight = 58;
  static const double _margin = 10;

  final Queue<int> _frameFinishUs = Queue<int>();
  final Queue<int> _frameSpanUs = Queue<int>();
  int _sumSpanUs = 0;

  Timer? _refreshTimer;
  int _fps = 0;
  double _avgFrameMs = 0;
  double _rssMb = 0;
  double _maxRssMb = 0;
  double _imgMb = 0;
  int _imgCount = 0;

  Offset? _offset;

  @override
  void initState() {
    super.initState();
    _sampleMemory();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _refreshTimer = Timer.periodic(_window, (_) => _onTick());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    for (final timing in timings) {
      final spanUs = timing.totalSpan.inMicroseconds;
      _frameFinishUs.addLast(nowUs);
      _frameSpanUs.addLast(spanUs);
      _sumSpanUs += spanUs;
    }
    _pruneOldFrames(nowUs);
  }

  void _pruneOldFrames(int nowUs) {
    final cutoffUs = nowUs - _window.inMicroseconds;
    while (_frameFinishUs.isNotEmpty && _frameFinishUs.first < cutoffUs) {
      _frameFinishUs.removeFirst();
      _sumSpanUs -= _frameSpanUs.removeFirst();
    }
  }

  void _sampleMemory() {
    _rssMb = ProcessInfo.currentRss / (1024 * 1024);
    _maxRssMb = ProcessInfo.maxRss / (1024 * 1024);
    final cache = PaintingBinding.instance.imageCache;
    _imgMb = cache.currentSizeBytes / (1024 * 1024);
    _imgCount = cache.currentSize;
  }

  void _onTick() {
    if (!mounted) return;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    _pruneOldFrames(nowUs);
    final count = _frameFinishUs.length;
    final avgMs = count > 0 ? (_sumSpanUs / count) / 1000.0 : 0.0;
    _sampleMemory();
    setState(() {
      _fps = count;
      _avgFrameMs = avgMs;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxX = (constraints.maxWidth - _pillWidth - _margin)
            .clamp(_margin, double.infinity);
        final minY = pad.top + _margin;
        final maxY = (constraints.maxHeight - _pillHeight - pad.bottom - _margin)
            .clamp(minY, double.infinity);

        final pos = _offset ?? Offset(maxX, minY);
        final left = pos.dx.clamp(_margin, maxX);
        final top = pos.dy.clamp(minY, maxY);

        final frameStr = _fps > 0
            ? '${_avgFrameMs.toStringAsFixed(1)}ms'
            : '--';

        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _offset = Offset(
                      (left + details.delta.dx).clamp(_margin, maxX),
                      (top + details.delta.dy).clamp(minY, maxY),
                    );
                  });
                },
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: _pillWidth,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.78),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                    ),
                    child: DefaultTextStyle(
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.32,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'FPS $_fps  ($frameStr)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _fps >= 50 || _fps == 0
                                  ? const Color(0xFF8CE99A)
                                  : (_fps >= 25
                                      ? const Color(0xFFFFE066)
                                      : const Color(0xFFFF8787)),
                            ),
                          ),
                          Text(
                            'RAM ${_rssMb.toStringAsFixed(0)} MB (pk ${_maxRssMb.toStringAsFixed(0)})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'IMG ${_imgMb.toStringAsFixed(1)} MB ($_imgCount)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.76),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
