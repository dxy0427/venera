import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webdav_comics/streaming_zip.dart';

void main() {
  final url = Platform.environment['VENERA_WEBDAV_TEST_URL'];
  final user = Platform.environment['VENERA_WEBDAV_TEST_USER'];
  final pass = Platform.environment['VENERA_WEBDAV_TEST_PASS'];
  final size = int.tryParse(
    Platform.environment['VENERA_WEBDAV_TEST_SIZE'] ?? '',
  );

  test(
    'lists entries from a real WebDAV archive',
    () async {
      final reader = StreamingZipReader(
        webdavUrl: url!,
        user: user!,
        pass: pass!,
        knownFileSize: size,
        adapter: IOHttpClientAdapter(),
      );
      addTearDown(reader.dispose);

      final entries = await reader.listEntries();

      expect(entries, isNotEmpty);
      expect(entries.where((entry) => !entry.isDirectory), isNotEmpty);
    },
    skip: url == null || user == null || pass == null,
  );
}
