import 'package:flutter/services.dart';

/// Method channel to the bundled yt-dlp engine (youtubedl-android).
///
/// Methods:
///   `init`                 -> the bundled yt-dlp version
///   `download` {url, outputDir, processId}
///                          -> runs yt-dlp; streams progress to
///                             [ytDlpProgressEvents] and completes when done
///   `cancel` {processId}   -> kills a running download
const MethodChannel ytDlpChannel = MethodChannel('peerm/ytdlp');

/// Live `[download] NN% of XXMiB` progress lines while a download runs.
const EventChannel ytDlpProgressEvents = EventChannel('peerm/ytdlp/progress');
