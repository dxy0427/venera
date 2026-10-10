import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/images.dart';

class _Cache implements CacheManager {
  final written = <String, List<int>>{};
  Future<File?> Function()? lookup;
  @override
  Future<File?> findCache(String key) => lookup?.call() ?? Future.value(null);
  @override
  Future<void> writeCache(String key, List<int> bytes, [int? duration]) async {
    written[key] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Cache cache;
  late HttpServer server;
  late String url;
  final clients = <Dio>[];

  setUp(() async {
    final oldCache = CacheManager.instance;
    addTearDown(() => CacheManager.instance = oldCache);
    cache = _Cache();
    CacheManager.instance = cache;
    ImageDownloader.httpClientFactory = (options) {
      final dio = Dio(options)..httpClientAdapter = IOHttpClientAdapter();
      clients.add(dio);
      return dio;
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/page';
  });
  tearDown(() async {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.httpClientFactory = null;
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    await server.close(force: true);
  });

  test(
    'chapter cancellation closes a stalled real HTTP transfer without caching or retrying',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\nx');
        await socket.flush();
        socket.listen(
          (_) {},
          onError: (Object error) {
            if (error is! SocketException) throw error;
            socket.destroy();
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onDone: () {
            socket.destroy();
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
        started.complete();
      });
      final stream = ImageDownloader.loadComicImage(
        url,
        null,
        'comic',
        'chapter',
      );
      final result = expectLater(
        stream.drain<void>(),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      ImageDownloader.cancelComicImages(null, 'comic', 'chapter');
      await result;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(cache.written, isEmpty);
      expect(requests, 1);
    },
  );

  test(
    'cancelling one listener preserves the shared request for another reader',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        started.complete();
        await release.future;
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final first = ImageDownloader.loadComicImage(
        url,
        null,
        'c',
        'e',
      ).listen((_) {});
      final second = ImageDownloader.loadComicImage(url, null, 'c', 'e').last;
      await started.future;
      await first.cancel();
      release.complete();
      expect((await second).imageBytes, [1, 2, 3]);
      expect(requests, 1);
    },
  );

  test(
    'an old cancelled load cannot remove its replacement or cancel another chapter',
    () async {
      final lookups = <Completer<File?>>[];
      cache.lookup = () {
        final completer = Completer<File?>();
        lookups.add(completer);
        return completer.future;
      };
      server.listen((request) async {
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final old = ImageDownloader.loadComicImage(
        url,
        null,
        'c',
        'e',
      ).listen((_) {}, onError: (_) {});
      await Future<void>.delayed(Duration.zero);
      final otherChapter = ImageDownloader.loadComicImage(
        url,
        null,
        'c',
        'other',
      ).last;
      await Future<void>.delayed(Duration.zero);
      ImageDownloader.cancelComicImages(null, 'c', 'e');
      final replacement = ImageDownloader.loadComicImage(
        url,
        null,
        'c',
        'e',
      ).last;
      await Future<void>.delayed(Duration.zero);
      lookups[0].complete(null);
      await Future<void>.delayed(Duration.zero);
      final duplicate = ImageDownloader.loadComicImage(
        url,
        null,
        'c',
        'e',
      ).last;
      await Future<void>.delayed(Duration.zero);
      expect(
        lookups,
        hasLength(3),
        reason: 'the replacement is still deduplicated',
      );
      lookups[1].complete(null);
      lookups[2].complete(null);
      for (final result in [replacement, duplicate, otherChapter]) {
        expect((await result).imageBytes, [1, 2, 3]);
      }
      await old.cancel();
    },
  );
}
