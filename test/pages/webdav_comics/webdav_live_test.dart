import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webdav_comics/streaming_zip.dart';
import 'package:venera/pages/webdav_comics/webdav_accounts.dart';
import 'package:venera/pages/webdav_comics/webdav_client.dart';
import 'package:venera/utils/natural_sort.dart';

void main() {
  final url = Platform.environment['VENERA_WEBDAV_TEST_URL'];
  final user = Platform.environment['VENERA_WEBDAV_TEST_USER'];
  final pass = Platform.environment['VENERA_WEBDAV_TEST_PASS'];
  final imageUrl = Platform.environment['VENERA_WEBDAV_TEST_IMAGE_URL'];
  final size = int.tryParse(
    Platform.environment['VENERA_WEBDAV_TEST_SIZE'] ?? '',
  );

  test(
    'reads and decodes a real WebDAV image without temporary files',
    () async {
      final uri = Uri.parse(imageUrl!);
      final adapter = IOHttpClientAdapter();
      addTearDown(() => adapter.close(force: true));
      final client = WebDavComicClient(
        WebDavAccount(
          id: 'live',
          name: 'Live test',
          url: uri.resolve('.').toString(),
          user: user!,
          pass: pass!,
        ),
        imageAdapter: adapter,
      );
      final bytes = await client.readImage(uri.pathSegments.last);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      print(
        'WebDAV image bytes=${bytes.length} decoded=${frame.image.width}x${frame.image.height}',
      );
      expect(frame.image.width, greaterThan(0));
      frame.image.dispose();
      codec.dispose();
    },
    skip: imageUrl == null || user == null || pass == null,
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
