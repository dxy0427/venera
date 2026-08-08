import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_cbz.dart';

void main() {
  final sourceRoot = Platform.environment['VENERA_ARCHIVE_CHAPTER_TEST_ROOT'];

  test('imports real archive chapter directories', () async {
    final root = await Directory.systemTemp.createTemp('archive-chapter-live-');
    addTearDown(() => root.delete(recursive: true));

    App.dataPath = root.path;
    App.cachePath = await Directory(
      '${root.path}/cache',
    ).create().then((directory) => directory.path);
    LocalManager().path = await Directory(
      '${root.path}/local',
    ).create().then((directory) => directory.path);

    final sourceDirectories =
        Directory(sourceRoot!).listSync().whereType<Directory>().toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    expect(sourceDirectories, isNotEmpty);

    for (final source in sourceDirectories) {
      final comic = await const ImportComic()
          .checkArchiveChapterDirectoryForTesting(source);
      expect(comic, isNotNull, reason: source.path);
      expect(comic!.chapters, isNotNull, reason: source.path);
      expect(comic.chapters!.length, greaterThan(0), reason: source.path);
      expect(File('${comic.baseDir}/${comic.cover}').existsSync(), isTrue);

      if (source.name == '原来，她们才是主角') {
        expect(comic.cover, 'cover.jpg');
        expect(comic.subtitle, isEmpty);
        expect(comic.chapters!.titles, ['预告 此女与我有缘呐', '01 前所未有的好苗子']);
      } else if (source.name == '狠狠后宫了之拯救七个女反派') {
        expect(comic.title, source.name);
        expect(comic.subtitle, '桔子文化');
        expect(comic.tags, containsAll(['题材:后宫', '题材:穿越', '状态:连载中']));
        expect(comic.cover, 'cover.jpg');
        expect(comic.chapters!.titles, ['第0话', '第1话', '后记']);
      }

      for (final chapterId in comic.chapters!.ids) {
        final sourceArchive = File('${source.path}/$chapterId');
        final importedArchive = File('${comic.baseDir}/$chapterId');
        expect(importedArchive.existsSync(), isTrue, reason: chapterId);
        expect(Directory(importedArchive.path).existsSync(), isFalse);
        expect(await importedArchive.length(), await sourceArchive.length());

        final images = await LocalCbzReader.listImageReferences(
          importedArchive.path,
        );
        expect(images, isNotEmpty, reason: importedArchive.path);
        final indexes = <int>{0, images.length ~/ 2, images.length - 1};
        for (final index in indexes) {
          expect(
            await LocalCbzReader.readReference(images[index]),
            isNotEmpty,
            reason: '${importedArchive.path} page $index',
          );
        }
      }
    }
  }, skip: sourceRoot == null);
}
