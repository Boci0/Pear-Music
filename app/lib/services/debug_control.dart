import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../controllers/app_controller.dart';

/// Debug-only remote control for UI review. Listens on 127.0.0.1:8787 and is
/// never started in profile or release builds.
///
///   /songs        list library songs with their index
///   /play?i=N     play library song N
///   /toggle       play / pause
///   /shot         PNG of the app's own render (no desktop capture)
Future<void> startDebugControl(AppController controller) async {
  if (!kDebugMode) return;
  try {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      8787,
      shared: true,
    );
    server.listen((req) async {
      try {
        final res = req.response;
        switch (req.uri.path) {
          case '/songs':
            final songs = controller.songs;
            res.write([
              for (var i = 0; i < songs.length; i++) '$i ${songs[i].title}',
            ].join('\n'));
          case '/play':
            final i = int.tryParse(req.uri.queryParameters['i'] ?? '') ?? 0;
            final songs = controller.songs;
            if (i < 0 || i >= songs.length) {
              res.statusCode = 400;
              res.write('index out of range');
            } else {
              unawaited(controller.playSong(songs[i]));
              res.write('playing ${songs[i].title}');
            }
          case '/toggle':
            await controller.togglePlayback();
            res.write('ok');
          case '/shot':
            final view = RendererBinding.instance.renderViews.first;
            final layer = view.debugLayer;
            if (layer is! OffsetLayer) {
              res.statusCode = 500;
              res.write('no layer');
            } else {
              final image = await layer.toImage(
                Offset.zero & view.size,
                pixelRatio: 1.0,
              );
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              res.headers.contentType = ContentType('image', 'png');
              res.add(data!.buffer.asUint8List());
            }
          default:
            res.statusCode = 404;
        }
        await res.close();
      } catch (e) {
        req.response.statusCode = 500;
        req.response.write('$e');
        await req.response.close();
      }
    });
  } catch (_) {}
}
