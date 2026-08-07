import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webdav_comics/streaming_zip.dart';
import 'package:venera/utils/natural_sort.dart';

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

      final entries =
          (await reader.listEntries())
              .where((entry) => !entry.isDirectory)
              .toList()
            ..sort((a, b) => naturalComparePath(a.fileName, b.fileName));

      expect(entries, isNotEmpty);
      final indexes = <int>{0, entries.length ~/ 2, entries.length - 1};
      for (final index in indexes) {
        final bytes = await reader.readEntry(entries[index].fileName);
        expect(
          bytes,
          isNotEmpty,
          reason: 'Failed to read ${entries[index].fileName}',
        );
      }
    },
    skip: url == null || user == null || pass == null,
  );
}
