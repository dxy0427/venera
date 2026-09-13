import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/webdav_comics/webdav_image_provider.dart';

void main() {
  group('getChapterDirectoryNameFor', () {
    test('WebDAV chapter uses its title as the directory name', () {
      const chapterId =
          'webdav://resource/v1?accountId=abc&path=%2F%E7%AC%AC0%E8%AF%9D.cbz&kind=chapter';
      final chapters = ComicChapters(const {chapterId: '第0话'});
      expect(
        LocalManager.getChapterDirectoryNameFor(chapters, chapterId),
        '第0话',
      );
    });

    test('non-WebDAV chapter keeps the id as the directory name', () {
      final chapters = ComicChapters(const {'1': '第0话', '2': '番外'});
      expect(LocalManager.getChapterDirectoryNameFor(chapters, '1'), '1');
      expect(LocalManager.getChapterDirectoryNameFor(chapters, '2'), '2');
    });

    test('WebDAV chapter with a missing/empty title falls back to the id', () {
      const chapterId =
          'webdav://resource/v1?accountId=abc&path=%2Fx.cbz&kind=chapter';
      final chapters = ComicChapters(const {chapterId: ''});
      final name = LocalManager.getChapterDirectoryNameFor(chapters, chapterId);
      // The id contains ':' '/' '?' '=' which get sanitized to '_'.
      expect(name, startsWith('webdav___resource_v1'));
    });

    test('chapter title with path separators is sanitized', () {
      const chapterId =
          'webdav://resource/v1?accountId=abc&path=%2Fx.cbz&kind=chapter';
      final chapters = ComicChapters(const {chapterId: '第1/2话'});
      expect(
        LocalManager.getChapterDirectoryNameFor(chapters, chapterId),
        '第1_2话',
      );
    });
  });

  group('WebDavReaderImageProvider', () {
    test('loads file:// images directly without reference parsing', () async {
      final tmp = await Directory.systemTemp.createTemp('webdav_img_test_');
      try {
        final file = File('${tmp.path}/1.jpg');
        await file.writeAsBytes([1, 2, 3, 4, 5]);
        final provider = WebDavReaderImageProvider(
          'file://${file.path}',
          page: 0,
        );
        final bytes = await provider.load(StreamController(), () {});
        expect(bytes, [1, 2, 3, 4, 5]);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
