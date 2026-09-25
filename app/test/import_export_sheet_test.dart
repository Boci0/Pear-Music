import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/import_export_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'import & export sheet lists the options and returns the pick',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final library = LibraryService();
      final controller = AppController(
        identity: IdentityService(prefs),
        library: library,
        player: PlayerService(library),
        youtube: YoutubeService(),
      );

      ImportExportAction? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showImportExportSheet(context, controller);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Import & export'), findsOneWidget);
      expect(find.text('Export backup'), findsOneWidget);
      expect(find.text('Restore backup'), findsOneWidget);
      // An empty library has nothing to back up yet.
      expect(find.textContaining('Nothing to back up yet'), findsOneWidget);

      await tester.tap(find.text('Export backup'));
      await tester.pumpAndSettle();
      expect(picked, isNull, reason: 'export is disabled with nothing to save');
      expect(find.text('Import playlists'), findsOneWidget);

      await tester.tap(find.text('Import playlists'));
      await tester.pumpAndSettle();
      expect(picked, ImportExportAction.importPlaylists);
      expect(find.text('Import & export'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
