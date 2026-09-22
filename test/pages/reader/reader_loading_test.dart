import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

class _ReaderSource implements ComicSource {
  int chapterLoads = 0;
  final imageLoads = <String>[];

  @override
  String get key => 'reader-test';

  @override
  int get intKey => key.hashCode;

  @override
  String get name => 'Reader test';

  @override
  ChapterCommentsLoader? get chapterCommentsLoader => null;

  @override
  LoadComicPagesFunc get loadComicPages => (cid, eid) async {
    chapterLoads++;
    return Res(List.generate(11, (index) => '$index'));
  };

  @override
  GetImageLoadingConfigFunc get getImageLoadingConfig =>
      (image, cid, eid) async {
        imageLoads.add(image);
        throw 'Invalid Status Code: 404';
      };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReaderCache implements CacheManager {
  _ReaderCache(this.directory, this.image);

  final Directory directory;
  final File image;
  final deletedKeys = <String>[];
  final chapterFiles = <String, File>{};
  bool failMiddle = true;

  /// When set, the next [findCache] for this key returns an empty file once,
  /// simulating a poisoned cache entry from an old empty download.
  String? emptyOnceKey;

  @override
  Future<File?> findCache(String key) async {
    if (key.startsWith('loadComicPages@')) return chapterFiles[key];
    if (key == emptyOnceKey) {
      emptyOnceKey = null;
      return File('${directory.path}/poisoned.png')..writeAsBytesSync(const []);
    }
    if (key.startsWith('5@') && failMiddle) return null;
    return image;
  }

  @override
  Future<void> writeCache(String key, List<int> data, [int? duration]) async {
    if (!key.startsWith('loadComicPages@')) return;
    final file = File('${directory.path}/chapter.json')..writeAsBytesSync(data);
    chapterFiles[key] = file;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    chapterFiles.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReaderHistoryManager extends HistoryManager {
  _ReaderHistoryManager() : super.create();

  @override
  Future<void> addHistoryAsync(History history) async {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File image;
  late _ReaderSource source;
  late _ReaderCache cache;
  CacheManager? oldCache;
  HistoryManager? oldHistory;
  late Map<String, dynamic> oldSettings;

  setUpAll(() async {
    await AppTranslation.init();
    directory = await Directory.systemTemp.createTemp('venera-reader-test-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    App.version = 'test';
    LocalManager().initForTesting(directory.path);
    final decoded = await createTestImage(width: 200, height: 300);
    final bytes = await decoded.toByteData(format: ui.ImageByteFormat.png);
    image = await File(
      '${directory.path}/page.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    decoded.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_memory_info'),
      (call) async => null,
    );
  });

  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_memory_info'),
      null,
    );
    await directory.delete(recursive: true);
  });

  setUp(() async {
    source = _ReaderSource();
    ComicSourceManager().add(source);
    oldCache = CacheManager.instance;
    cache = _ReaderCache(directory, image);
    CacheManager.instance = cache;
    oldHistory = HistoryManager.cache;
    HistoryManager.cache = _ReaderHistoryManager();
    await HistoryManager().init();
    final settings = {
      'readerMode': 'continuousTopToBottom',
      'preloadImageCount': 0,
      'enablePageAnimation': false,
      'enableClockAndBatteryInfoInReader': false,
      'showPageNumberInReader': true,
      'enableDoubleTapToZoom': false,
      'limitImageWidth': false,
      'language': 'en-US',
      'readerScreenPicNumberForLandscape': 1,
      'readerScreenPicNumberForPortrait': 1,
      'showSingleImageOnFirstPage': false,
    };
    oldSettings = {for (final key in settings.keys) key: appdata.settings[key]};
    settings.forEach((key, value) => appdata.settings[key] = value);
  });

  tearDown(() {
    ImageDownloader.cancelAllLoadingImages();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicImage.clear();
    CacheManager.instance = oldCache;
    HistoryManager().close();
    HistoryManager.cache = oldHistory;
    ComicSourceManager().remove(source.key);
    oldSettings.forEach((key, value) => appdata.settings[key] = value);
  });

  Future<void> pumpReader(WidgetTester tester) async {
    final history = History.fromMap({
      'id': 'comic',
      'type': source.intKey,
      'time': 0,
      'title': 'Test comic',
      'subtitle': '',
      'cover': '',
      'ep': 1,
      'page': 1,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => WindowFrame(child!),
        home: Reader(
          type: ComicType(source.intKey),
          cid: 'comic',
          name: 'Test comic',
          chapters: null,
          history: history,
          author: '',
          tags: const [],
        ),
      ),
    );
    await settleReader(tester);
  }

  Future<void> openToolbar(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(Reader)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CustomSlider).hitTestable(), findsOneWidget);
  }

  Future<void> tapPage(WidgetTester tester, int page) async {
    final finder = find.descendant(
      of: find.byType(CustomSlider),
      matching: find.byType(GestureDetector),
    );
    final track = tester.getRect(finder);
    final slider = tester.widget<CustomSlider>(find.byType(CustomSlider));
    var fraction = (page - slider.min) / (slider.max - slider.min);
    if (slider.reversed) fraction = 1 - fraction;
    await tester.tapAt(
      Offset(
        track.left + track.width * fraction.clamp(0.001, 0.999),
        track.center.dy,
      ),
    );
    await tester.pump();
  }

  for (final animation in [false, true]) {
    testWidgets(
      'jump, image failure and retry preserve chapter (animation=$animation)',
      (tester) async {
        appdata.settings['enablePageAnimation'] = animation;
        await pumpReader(tester);
        expect(source.chapterLoads, 1);
        final chapterKey = 'loadComicPages@${source.key}@comic@0';
        expect(cache.chapterFiles, contains(chapterKey));
        expect(find.byType(RawImage), findsWidgets);

        // Open the real reader toolbar, then use its actual page slider.
        await openToolbar(tester);
        final slider = find.byType(CustomSlider);
        await tapPage(tester, 6);
        await settleReader(tester);

        expect(
          tester.widget<CustomSlider>(slider).value,
          6,
          reason: tester
              .widgetList<ComicImage>(find.byType(ComicImage))
              .map((widget) {
                final provider = widget.image as ReaderImageProvider;
                final finder = find.byWidget(widget);
                return '${provider.imageKey}: ${tester.getRect(finder)}';
              })
              .join('\n'),
        );
        expect(source.imageLoads, contains('5'));
        expect(find.text('Invalid Status Code: 404'), findsOneWidget);
        expect(source.chapterLoads, 1);
        expect(cache.deletedKeys, isNot(contains(chapterKey)));
        expect(
          jsonDecode(cache.chapterFiles[chapterKey]!.readAsStringSync()),
          hasLength(11),
        );

        for (final widget in tester.widgetList<ComicImage>(
          find.byType(ComicImage),
        )) {
          final provider = widget.image as ReaderImageProvider;
          expect(provider.page, int.parse(provider.imageKey) + 1);
        }

        cache.failMiddle = false;
        await tester.tap(find.text('Retry'));
        await settleReader(tester);
        expect(find.text('Invalid Status Code: 404'), findsNothing);
        expect(find.byType(RawImage), findsWidgets);
        expect(source.chapterLoads, 1);
        expect(cache.deletedKeys, isNot(contains(chapterKey)));
        expect(tester.widget<CustomSlider>(slider).value, 6);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  for (final mode in [
    'galleryLeftToRight',
    'galleryRightToLeft',
    'galleryTopToBottom',
  ]) {
    for (final count in [2, 3]) {
      testWidgets('$count images in $mode receive their actual page numbers', (
        tester,
      ) async {
        cache.failMiddle = false;
        appdata.settings['readerMode'] = mode;
        appdata.settings['readerScreenPicNumberForLandscape'] = count;
        appdata.settings['readerScreenPicNumberForPortrait'] = count;
        await pumpReader(tester);
        final widgets = tester.widgetList<ComicImage>(find.byType(ComicImage));
        expect(widgets.length, greaterThanOrEqualTo(count));
        for (final widget in widgets) {
          final provider = widget.image as ReaderImageProvider;
          expect(provider.page, int.parse(provider.imageKey) + 1);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      });
    }
  }

  for (final mode in [
    'continuousTopToBottom',
    'continuousLeftToRight',
    'continuousRightToLeft',
  ]) {
    testWidgets(
      '$mode animated jumps reach the requested image in both directions',
      (tester) async {
        cache.failMiddle = false;
        appdata.settings['readerMode'] = mode;
        appdata.settings['enablePageAnimation'] = true;
        await pumpReader(tester);
        await openToolbar(tester);
        for (final page in [9, 3, 11, 1]) {
          await tapPage(tester, page);
          await settleReader(tester);
          // At the end of a horizontal list the viewport may also contain a
          // preceding narrow image; its page counter is the first visible page.
          if (page != 11) {
            expect(
              tester.widget<CustomSlider>(find.byType(CustomSlider)).value,
              page,
            );
          }
          final target = find.byWidgetPredicate(
            (widget) =>
                widget is ComicImage &&
                (widget.image as ReaderImageProvider).imageKey == '${page - 1}',
          );
          expect(target, findsOneWidget);
          expect(
            tester
                .getRect(target)
                .overlaps(tester.getRect(find.byType(Reader))),
            isTrue,
          );
          expect(source.chapterLoads, 1);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets(
    'a newer page request wins while the previous animation is running',
    (tester) async {
      cache.failMiddle = false;
      appdata.settings['enablePageAnimation'] = true;
      await pumpReader(tester);
      await openToolbar(tester);
      await tapPage(tester, 9);
      await tester.pump(const Duration(milliseconds: 50));
      await tapPage(tester, 3);
      await settleReader(tester);
      expect(tester.widget<CustomSlider>(find.byType(CustomSlider)).value, 3);
      expect(source.chapterLoads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('an empty cached page self-heals and retry succeeds', (
    tester,
  ) async {
    final imageCacheKey = '5@${source.key}@comic@0';
    cache.emptyOnceKey = imageCacheKey;
    await pumpReader(tester);
    await openToolbar(tester);
    await tapPage(tester, 6);
    await settleReader(tester);

    // The poisoned empty entry is removed instead of trapping the page.
    expect(cache.deletedKeys, contains(imageCacheKey));
    expect(source.imageLoads, contains('5'));
    expect(find.text('Invalid Status Code: 404'), findsOneWidget);
    // The chapter page list is loaded once and never invalidated.
    expect(source.chapterLoads, 1);
    expect(
      cache.deletedKeys,
      isNot(contains('loadComicPages@${source.key}@comic@0')),
    );

    // Retry re-reads the (now clean) cache and succeeds.
    cache.failMiddle = false;
    await tester.tap(find.text('Retry'));
    await settleReader(tester);
    expect(find.text('Invalid Status Code: 404'), findsNothing);
    expect(find.byType(RawImage), findsWidgets);
    expect(source.chapterLoads, 1);
    expect(tester.widget<CustomSlider>(find.byType(CustomSlider)).value, 6);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'closing the reader during a jump does not update disposed state',
    (tester) async {
      cache.failMiddle = false;
      appdata.settings['enablePageAnimation'] = true;
      await pumpReader(tester);
      await openToolbar(tester);
      await tapPage(tester, 9);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> settleReader(WidgetTester tester) async {
  // File reads and image decoding run outside the fake clock. Pump bounded
  // frames because an image's indeterminate progress intentionally animates.
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
