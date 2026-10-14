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

  Future<void> showTile(WidgetTester tester, {String display = 'brief'}) async {
    appdata.settings['comicDisplayMode'] = display;
    final comic = Comic(
      'Long press details test',
      'file://${coverFile.path}',
      'comic-id',
      'Author',
      const [],
      'Description',
      'source-key',
      12,
      'en',
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(child: ComicTile(comic: comic)),
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
}
