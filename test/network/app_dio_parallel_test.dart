import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  late HttpServer server;
  late String base;
  final clients = <AppDio>[];
  final seen = <String>[];
  late Completer<void> first;
  late Completer<void> release;

  AppDio client() {
    final dio = AppDio(BaseOptions(baseUrl: base))
      ..httpClientAdapter = IOHttpClientAdapter();
    clients.add(dio);
    return dio;
  }

  Options options(
    String id, {
    bool serialized = true,
    ResponseType? responseType,
  }) => Options(
    headers: {'x-test-id': id, if (serialized) 'prevent-parallel': 'true'},
    responseType: responseType,
  );

  setUp(() async {
    seen.clear();
    first = Completer<void>();
    release = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final id = request.headers.value('x-test-id')!;
      expect(request.headers.value('prevent-parallel'), isNull);
      seen.add(id);
      if (id == 'first') {
        request.response.write('part');
        await request.response.flush();
        first.complete();
        await release.future;
      }
      if (id == 'error') request.response.statusCode = 500;
      request.response.write('ok');
      try {
        await request.response.close();
      } on SocketException {
        /* cancelled client */
      }
    });
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    for (final dio in clients) {
      dio.close(force: true);
    }
    clients.clear();
    await server.close(force: true);
  });

  test(
    'resolved URLs serialize across clients until the body completes',
    () async {
      final a = client();
      final b = client();
      final firstRequest = a.get('/image', options: options('first'));
      await first.future;
      final reused = options('second');
      final second = b.get('$base/image', options: reused);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, ['first']);
      expect(reused.headers!['prevent-parallel'], 'true');
      release.complete();
      expect((await firstRequest).data, 'partok');
      expect((await second).data, 'ok');
      expect(seen, ['first', 'second']);
    },
  );

  test(
    'a cancelled waiter does not unlock its predecessor or reach the server',
    () async {
      final dio = client();
      final active = dio.get('/image', options: options('first'));
      await first.future;
      final token = CancelToken();
      final cancelled = expectLater(
        dio.get('/image', options: options('cancelled'), cancelToken: token),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final next = dio.get('/image', options: options('next'));
      token.cancel();
      await cancelled.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, ['first']);
      release.complete();
      await Future.wait([active, next]);
      expect(seen, ['first', 'next']);
    },
  );

  test('unflagged requests cannot release another request lock', () async {
    final dio = client();
    final active = dio.get('/image', options: options('first'));
    await first.future;
    await dio.get('/image', options: options('ordinary', serialized: false));
    final next = dio.get('/image', options: options('next'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(seen, ['first', 'ordinary']);
    release.complete();
    await Future.wait([active, next]);
  });

  test('failed requests release the queue', () async {
    final dio = client();
    final failed = expectLater(
      dio.get('/image', options: options('error')),
      throwsA(isA<DioException>()),
    );
    final next = dio.get('/image', options: options('next'));
    await failed;
    expect((await next).data, 'ok');
    expect(seen, ['error', 'next']);
  });

  test(
    'stream responses hold the queue until their subscription is cancelled',
    () async {
      final dio = client();
      final response = await dio.get<ResponseBody>(
        '/image',
        options: options('first', responseType: ResponseType.stream),
      );
      final next = dio.get('/image', options: options('next'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, ['first']);
      await response.data!.stream.listen((_) {}).cancel();
      expect((await next).data, 'ok');
      expect(seen, ['first', 'next']);
    },
  );
}
