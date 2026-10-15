import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart' show Comic;
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/utils/translations.dart';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getTemporaryPath() async => dir;

  @override
  Future<String?> getApplicationCachePath() async => dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;

  @override
  Future<String?> getExternalStoragePath() async => dir;

  @override
  Future<String?> getDownloadsPath() async => dir;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File coverFile;

  setUpAll(() async {
    await AppTranslation.init();
    temp = Directory.systemTemp.createTempSync('comic-tile-menu-');
    PathProviderPlatform.instance = _TempPathProvider(temp.path);
    App.dataPath = temp.path;
    App.cachePath = temp.path;
    await ReadLaterManager().init();
    final image = await createTestImage(width: 20, height: 30);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    coverFile = await File(
      '${temp.path}/cover.png',
    ).writeAsBytes(bytes.buffer.asUint8List());
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  /// Dismiss routes and let toast/image timers finish before test end.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  Comic buildComic({List<String> tags = const []}) {
    return Comic(
      'Long press details test',
      'file://${coverFile.path}',
      'comic-id',
      'Author',
      tags,
      'Description',
      'source-key',
      12,
      'en',
    );
  }

  Future<void> showTile(
    WidgetTester tester, {
    String display = 'brief',
    List<String> tags = const [],
  }) async {
    appdata.settings['comicDisplayMode'] = display;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(
              child: ComicTile(comic: buildComic(tags: tags)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Long press details test'), findsOneWidget);
  }

  testWidgets('brief tile long press opens the detail/copy menu', (
    tester,
  ) async {
    await showTile(tester);
    await tester.longPress(find.textContaining('Long press details test'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Copy Title'), findsOneWidget);
    expect(find.text('Add to favorites'), findsOneWidget);
    expect(find.text('Read Later'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('detailed tile long press opens the detail/copy menu', (
    tester,
  ) async {
    await showTile(tester, display: 'detailed');
    await tester.longPress(find.textContaining('Long press details test'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Copy Title'), findsOneWidget);
    expect(find.text('Read Later'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('copy title writes the comic title to the clipboard', (
    tester,
  ) async {
    final channel = SystemChannels.platform;
    String? copied;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await showTile(tester);
    await tester.longPress(find.textContaining('Long press details test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Title'));
    await tester.pumpAndSettle();
    expect(copied, 'Long press details test');
    expect(find.text('Copy Title'), findsNothing, reason: 'menu dismisses');
    await settle(tester);
  });

  testWidgets('read later entry reflects state and toggles with correct type', (
    tester,
  ) async {
    await showTile(tester);
    final type = ComicType.fromKey('source-key');
    expect(ReadLaterManager().exists('comic-id', type), isFalse);
    await tester.longPress(find.textContaining('Long press details test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read Later'));
    await tester.pumpAndSettle();
    expect(ReadLaterManager().exists('comic-id', type), isTrue);

    await tester.longPress(find.textContaining('Long press details test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from Read Later'));
    await tester.pumpAndSettle();
    expect(ReadLaterManager().exists('comic-id', type), isFalse);
    await settle(tester);
  });

  testWidgets(
    'detailed tile renders the metadata and never mutates the tag list',
    (tester) async {
      // Real feeds hand over shared growable lists (the other tests cover
      // read-only const lists): the widget must neither mutate them nor
      // turn blank entries into visible chips.
      final tags = <String>['Tag A', '  ', 'Tag B\nnext'];
      await showTile(tester, display: 'detailed', tags: tags);
      expect(find.text('Author'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      expect(find.text('Tag A'), findsOneWidget);
      expect(find.text('Tag B next'), findsOneWidget);
      expect(tags, [
        'Tag A',
        '  ',
        'Tag B\nnext',
      ], reason: 'caller list intact');
      await settle(tester);
    },
  );

  testWidgets('long press anchors the menu at the tile center like prime', (
    tester,
  ) async {
    appdata.settings['comicDisplayMode'] = 'detailed';
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(
              child: SizedBox(
                width: 480,
                height: 200,
                child: ComicTile(comic: buildComic()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tile = tester.getRect(find.byType(ComicTile));
    await tester.longPress(find.textContaining('Long press details test'));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(PopoverSurface));
    // venera-prime calls localToGlobal(Offset((width - 242) / 2, height / 2)),
    // so the menu top-left sits at the tile's horizontal center minus half
    // the menu width, vertically centered on the tile.
    expect(
      menu.topLeft,
      Offset(tile.left + (tile.width - 242) / 2, tile.top + tile.height / 2),
    );
    expect(menu.center.dx, moreOrLessEquals(tile.center.dx));
    await settle(tester);
  });
}
