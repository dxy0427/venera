import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/pages/webdav_comics/webdav_accounts.dart';
import 'package:venera/pages/webdav_comics/webdav_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List png;
  late HttpServer server;
  late WebDavComicClient client;
  late IOHttpClientAdapter adapter;
  final paths = <String>[];
  setUpAll(() async {
    final oldHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = oldHttpOverrides);
    final image = await createTestImage(width: 20, height: 30);
    png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
  });
  setUp(() async {
    paths.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    adapter = IOHttpClientAdapter();
    client = WebDavComicClient(
      WebDavAccount(
        id: 'test',
        name: 'Test',
        url: 'http://127.0.0.1:${server.port}/dav',
        user: 'user',
        pass: 'synthetic',
      ),
      imageAdapter: adapter,
    );
  });
  tearDown(() async {
    adapter.close(force: true);
    await server.close(force: true);
  });

  test(
    'direct GET preserves PNG bytes, auth and encoded names without temporary files',
    () async {
      final before = Directory.systemTemp
          .listSync()
          .map((file) => file.path)
          .toSet();
      server.listen((request) async {
        paths.add(request.method);
        expect(request.uri.pathSegments, ['dav', '漫画', '第 1 页.png']);
        expect(
          request.headers.value('authorization'),
          'Basic ${base64Encode(utf8.encode('user:synthetic'))}',
        );
        request.response.add(png);
        await request.response.close();
      });
      final bytes = await client.readImage('/漫画/第 1 页.png');
      expect(bytes, png);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 20);
      frame.image.dispose();
      codec.dispose();
      expect(paths, ['GET']);
      expect(
        Directory.systemTemp.listSync().where(
          (file) =>
              !before.contains(file.path) && file.path.contains('webdav_temp_'),
        ),
        isEmpty,
      );
    },
  );

  test('cancellation disconnects a stalled WebDAV image transfer', () async {
    final started = Completer<void>();
    final disconnected = Completer<void>();
    server.listen((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\nx');
      await socket.flush();
      void closed() {
        socket.destroy();
        if (!disconnected.isCompleted) disconnected.complete();
      }

      socket.listen(
        (_) {},
        onDone: closed,
        onError: (Object error) {
          if (error is! SocketException) throw error;
          closed();
        },
      );
      started.complete();
    });
    final token = CancelToken();
    final result = expectLater(
      client.readImage('/page.png', cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;
    token.cancel();
    await result;
    await disconnected.future.timeout(const Duration(seconds: 3));
  });

  test('empty and failed responses do not become valid image data', () async {
    server.listen((request) async {
      request.response.statusCode = request.uri.path.endsWith('missing.png')
          ? 404
          : 200;
      await request.response.close();
    });
    await expectLater(
      client.readImage('/missing.png'),
      throwsA(isA<DioException>()),
    );
    await expectLater(
      client.readImage('/empty.png'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('Empty image data'),
        ),
      ),
    );
  });
}
