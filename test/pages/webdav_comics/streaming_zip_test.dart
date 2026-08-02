import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
}

enum _RangeBehavior { partial, ignore }

Future<HttpServer> _startArchiveServer(
  Uint8List bytes, {
  required _RangeBehavior behavior,
  void Function(HttpRequest request)? onRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
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
