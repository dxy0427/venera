import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/network/images.dart';

class _FakeCache implements CacheManager {
  final deletedKeys = <String>[];
  final written = <String, List<int>>{};
  final poisoned = <String, File>{};

  @override
  Future<File?> findCache(String key) async {
    final file = poisoned.remove(key);
    if (file != null) return file;
    return null;
  }

  @override
  Future<void> writeCache(String key, List<int> data, [int? duration]) async {
    written[key] = data;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late File emptyFile;
  late File validFile;
  late _FakeCache cache;
  CacheManager? previousCache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('venera-images-test-');
    emptyFile = File('${temp.path}/empty.png')..writeAsBytesSync([]);
    validFile = File('${temp.path}/page.png')..writeAsBytesSync([1, 2, 3, 4]);
    previousCache = CacheManager.instance;
    cache = _FakeCache();
    CacheManager.instance = cache;
  });

  tearDown(() {
    CacheManager.instance = previousCache;
    temp.deleteSync(recursive: true);
  });

  Future<Object> collectError(Stream<Object> stream) async {
    try {
      await stream.drain<void>();
    } catch (e) {
      return e;
    }
    throw StateError('expected the stream to fail');
  }

  test('an empty source file is reported and never cached', () async {
    final imageKey = 'file://${emptyFile.path}';
    final key = ImageDownloader.cacheKeyFor(imageKey, null, 'c@e');

    final error = await collectError(
      ImageDownloader.loadComicImageUnwrapped(imageKey, null, 'c', 'e'),
    );

    expect(error.toString(), contains('Empty image data'));
    expect(
      cache.written,
      isNot(contains(key)),
      reason: 'empty bytes must not poison the cache',
    );
    expect(cache.deletedKeys, isEmpty);
  });

  test(
    'a poisoned empty cache entry is removed before loading fresh data',
    () async {
      final imageKey = 'file://${validFile.path}';
      final key = ImageDownloader.cacheKeyFor(imageKey, null, 'c@e');
      cache.poisoned[key] = emptyFile;

      final events = await ImageDownloader.loadComicImageUnwrapped(
        imageKey,
        null,
        'c',
        'e',
      ).toList();

      expect(cache.deletedKeys, [
        key,
      ], reason: 'the empty cached entry must be invalidated');
      expect(events.last.imageBytes, [1, 2, 3, 4]);
      expect(cache.written[key], [
        1,
        2,
        3,
        4,
      ], reason: 'fresh data must replace the poisoned entry');
    },
  );

  test('valid bytes are cached and returned without deletions', () async {
    final imageKey = 'file://${validFile.path}';
    final key = ImageDownloader.cacheKeyFor(imageKey, null, 'c@e');

    final events = await ImageDownloader.loadComicImageUnwrapped(
      imageKey,
      null,
      'c',
      'e',
    ).toList();

    expect(events.last.imageBytes, [1, 2, 3, 4]);
    expect(cache.written[key], [1, 2, 3, 4]);
    expect(cache.deletedKeys, isEmpty);
  });
}
