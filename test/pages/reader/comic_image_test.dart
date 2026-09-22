import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

class _ControlledReaderImage extends ReaderImageProvider {
  _ControlledReaderImage(String imageKey)
    : super(imageKey, 'test-source', 'comic', 'chapter', 1);

  final loadResults = <Completer<Uint8List>>[];
  late StreamController<ImageChunkEvent> chunks;
  int loads = 0;

  /// When set, every [load] fails with this error instead of waiting for a
  /// completer, simulating a source that keeps returning empty data.
  Object? autoError;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) {
    loads++;
    chunks = chunkEvents;
    if (autoError != null) {
      return Future<Uint8List>.error(autoError!);
    }
    while (loadResults.length < loads) {
      loadResults.add(Completer<Uint8List>());
    }
    return loadResults[loads - 1].future;
  }

  Completer<Uint8List> resultOf(int load) {
    while (loadResults.length <= load) {
      loadResults.add(Completer<Uint8List>());
    }
    return loadResults[load];
  }

  void progress(int loaded, int? total) {
    chunks.add(
      ImageChunkEvent(cumulativeBytesLoaded: loaded, expectedTotalBytes: total),
    );
  }
}

class _RecordingCacheManager implements CacheManager {
  final deletedKeys = <String>[];

  @override
  Future<void> delete(String key) async => deletedKeys.add(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List png;
  late _RecordingCacheManager cache;
  CacheManager? previousCache;

  setUpAll(() async {
    await AppTranslation.init();
    final image = await createTestImage(width: 20, height: 30);
    png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
  });

  setUp(() {
    previousCache = CacheManager.instance;
    cache = _RecordingCacheManager();
    CacheManager.instance = cache;
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicImage.clear();
    CacheManager.instance = previousCache;
  });

  Future<void> showImages(
    WidgetTester tester,
    List<_ControlledReaderImage> providers, {
    Key? key,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final provider in providers)
                SizedBox(
                  width: 200,
                  height: 400,
                  child: ComicImage(key: key, image: provider),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> completeImage(
    WidgetTester tester,
    _ControlledReaderImage provider, [
    int load = 0,
  ]) async {
    await tester.runAsync(() async {
      provider.resultOf(load).complete(png);
      final stream = provider.resolve(ImageConfiguration.empty);
      final decoded = Completer<void>();
      final listener = ImageStreamListener((image, synchronous) {
        image.dispose();
        decoded.complete();
      }, onError: decoded.completeError);
      stream.addListener(listener);
      await decoded.future;
      stream.removeListener(listener);
    });
    await tester.pump();
  }

  testWidgets(
    'known length fills the progress circle before showing the image',
    (tester) async {
      final provider = _ControlledReaderImage('known-length');
      await showImages(tester, [provider]);
      final indicator = find.byType(CircularProgressIndicator);
      expect(tester.widget<CircularProgressIndicator>(indicator).value, isNull);

      for (final loaded in [25, 60, 100]) {
        provider.progress(loaded, 100);
        await tester.pump();
        await tester.pump();
        expect(
          tester.widget<CircularProgressIndicator>(indicator).value,
          loaded / 100,
        );
        expect(find.byType(RawImage), findsNothing);
      }

      await completeImage(tester, provider);
      expect(indicator, findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(provider.loads, 1);
    },
  );

  testWidgets('unknown length keeps an indeterminate circle until decoded', (
    tester,
  ) async {
    final provider = _ControlledReaderImage('unknown-length');
    await showImages(tester, [provider]);
    for (final total in <int?>[null, 0]) {
      provider.progress(25, total);
      await tester.pump();
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
    }
    await completeImage(tester, provider);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('one failed image keeps its neighbor and the chapter cache', (
    tester,
  ) async {
    final good = _ControlledReaderImage('good-page');
    final bad = _ControlledReaderImage('failed-page');
    await showImages(tester, [good, bad]);
    await completeImage(tester, good);
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;

    bad.resultOf(0).completeError('Invalid Status Code: 404');
    await tester.pump();
    await tester.pump();

    expect(find.text('Invalid Status Code: 404'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    expect(good.loads, 1);
    expect(bad.loads, 1);
    expect(
      cache.deletedKeys,
      isNot(contains('loadComicPages@test-source@comic@chapter')),
      reason: 'a failed image must not invalidate the chapter page list',
    );
  });

  testWidgets('empty image data shows an error and a new resolve reloads it', (
    tester,
  ) async {
    final provider = _ControlledReaderImage('empty-then-valid');
    provider.autoError = Exception('Empty image data');
    await showImages(tester, [provider]);

    // A plain failure is retried internally with backoff (2s/4s/8s) before
    // it surfaces as an error.
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(provider.loads, greaterThan(1), reason: 'the load is retried');
    expect(find.textContaining('Empty image data'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);

    // Re-resolve, which is what the Retry button does. The failed completer
    // was evicted, so a fresh load starts. The button itself is covered by
    // the full reader test, where the gesture state it needs exists.
    final retry = _ControlledReaderImage('empty-then-valid');
    await showImages(tester, [retry], key: const ValueKey('retry'));
    expect(retry.loads, 1, reason: 'a new resolve must load again');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await completeImage(tester, retry, 0);
    expect(find.textContaining('Empty image data'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });
}
