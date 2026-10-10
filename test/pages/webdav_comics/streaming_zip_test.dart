import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/webdav_comics/streaming_zip.dart';

void main() {
  late Uint8List archiveBytes;

  setUpAll(() {
    App.version = 'test';
    final archive = Archive()
      ..addFile(ArchiveFile('001.jpg', 4, const [1, 2, 3, 4]));
    archiveBytes = ZipEncoder().encodeBytes(archive);
  });

  test('streams ZIP entries with validated byte ranges', () async {
    final acceptEncodings = <String?>[];
    final server = await _startArchiveServer(
      archiveBytes,
      behavior: _RangeBehavior.partial,
      onRequest: (request) {
        if (request.headers.value(HttpHeaders.rangeHeader) != null) {
          acceptEncodings.add(
            request.headers.value(HttpHeaders.acceptEncodingHeader),
          );
        }
      },
    );
    addTearDown(() => server.close(force: true));

    final reader = StreamingZipReader(
      webdavUrl: 'http://${server.address.host}:${server.port}/comic.cbz',
      user: 'user',
      pass: 'pass',
      knownFileSize: archiveBytes.length,
      adapter: IOHttpClientAdapter(),
    );
    addTearDown(reader.dispose);

    final entries = await reader.listEntries();
    final image = await reader.readEntry('001.jpg');

    expect(entries.map((entry) => entry.fileName), contains('001.jpg'));
    expect(image, const [1, 2, 3, 4]);
    expect(acceptEncodings, isNotEmpty);
    expect(acceptEncodings, everyElement('identity'));
  });

  test('rejects a server that ignores Range and returns 200', () async {
    final server = await _startArchiveServer(
      archiveBytes,
      behavior: _RangeBehavior.ignore,
    );
    addTearDown(() => server.close(force: true));

    final reader = StreamingZipReader(
      webdavUrl: 'http://${server.address.host}:${server.port}/comic.cbz',
      user: 'user',
      pass: 'pass',
      knownFileSize: archiveBytes.length,
      adapter: IOHttpClientAdapter(),
    );
    addTearDown(reader.dispose);

    await expectLater(
      reader.listEntries(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('ignored Range request'),
        ),
      ),
    );
  });

  test('does not forward Basic auth to a redirected CDN origin', () async {
    String? cdnAuthorization;
    late HttpServer origin;
    final cdn = await _startArchiveServer(
      archiveBytes,
      behavior: _RangeBehavior.partial,
      onRequest: (request) {
        cdnAuthorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
      },
    );
    addTearDown(() => cdn.close(force: true));

    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Basic ${base64Encode(utf8.encode('user:pass'))}',
      );
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://${cdn.address.host}:${cdn.port}/comic.cbz',
      );
      await request.response.close();
    });
    addTearDown(() => origin.close(force: true));

    final reader = StreamingZipReader(
      webdavUrl: 'http://${origin.address.host}:${origin.port}/comic.cbz',
      user: 'user',
      pass: 'pass',
      knownFileSize: archiveBytes.length,
      adapter: IOHttpClientAdapter(),
    );
    addTearDown(reader.dispose);

    await reader.listEntries();

    expect(cdnAuthorization, isNull);
  });

  test(
    'cancelling an entry closes its Range transfer and keeps metadata reusable',
    () async {
      var stall = false;
      final started = Completer<void>();
      final disconnected = Completer<void>();
      final server = await _startArchiveServer(
        archiveBytes,
        behavior: _RangeBehavior.partial,
        intercept: (request) async {
          if (!stall) return false;
          final range = RegExp(
            r'bytes=(\d+)-(\d+)',
          ).firstMatch(request.headers.value('range')!)!;
          final start = int.parse(range[1]!);
          final end = int.parse(range[2]!);
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 206 Partial Content\r\nContent-Length: ${end - start + 1}\r\nContent-Range: bytes $start-$end/${archiveBytes.length}\r\n\r\nx',
          );
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
          return true;
        },
      );
      addTearDown(() => server.close(force: true));
      final reader = StreamingZipReader(
        webdavUrl: 'http://127.0.0.1:${server.port}/comic.cbz',
        user: '',
        pass: '',
        knownFileSize: archiveBytes.length,
        adapter: IOHttpClientAdapter(),
      );
      addTearDown(reader.dispose);
      await reader.listEntries();
      stall = true;
      final token = CancelToken();
      final result = expectLater(
        reader.readEntry('001.jpg', cancelToken: token),
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
      stall = false;
      expect(await reader.readEntry('001.jpg'), [1, 2, 3, 4]);
    },
  );
}

enum _RangeBehavior { partial, ignore }

Future<HttpServer> _startArchiveServer(
  Uint8List bytes, {
  required _RangeBehavior behavior,
  void Function(HttpRequest request)? onRequest,
  Future<bool> Function(HttpRequest request)? intercept,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (await intercept?.call(request) == true) return;
    onRequest?.call(request);
    if (request.method == 'HEAD') {
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = bytes.length;
      await request.response.close();
      return;
    }

    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (behavior == _RangeBehavior.ignore || range == null) {
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
      return;
    }

    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    if (match == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final part = bytes.sublist(start, end + 1);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${bytes.length}',
    );
    request.response.contentLength = part.length;
    request.response.add(part);
    await request.response.close();
  });
  return server;
}
