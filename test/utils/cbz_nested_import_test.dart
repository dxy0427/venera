import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_cbz.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory local;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('archive-folder-import-');
    source = await Directory('${root.path}/source').create();
    local = await Directory('${root.path}/local').create();
    cache = await Directory('${root.path}/cache').create();
    App.dataPath = root.path;
    App.cachePath = cache.path;
    LocalManager().path = local.path;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('lists nested CBZ images in path-aware natural order', () async {
    final archive = await _writeCbz(source, 'chapter.cbz', {
      'Vol.10/001.jpg': [10],
      'Vol.2/010.jpg': [2, 10],
      'Vol.2/002.jpg': [2, 2],
    });

    final images = await LocalCbzReader.listImages(archive.path);

    expect(images.map((entry) => entry.fileName), [
      'Vol.2/002.jpg',
      'Vol.2/010.jpg',
      'Vol.10/001.jpg',
    ]);
  });

  test(
    'excludes an archive cover from chapter pages when other pages exist',
    () async {
      final archive = await _writeCbz(source, 'chapter.cbz', {
        'cover.jpg': [0],
        '001.jpg': [1],
        '002.jpg': [2],
      });

      final pages = await LocalCbzReader.listImageReferences(archive.path);

      expect(pages, hasLength(2));
      expect(await LocalCbzReader.readReference(pages.first), [1]);
      expect(await LocalCbzReader.readReference(pages.last), [2]);
    },
  );

  test('imports CBZ chapters without extracting them', () async {
    await File('${source.path}/cover.png').writeAsBytes([0]);
    await File('${source.path}/info.json').writeAsString('''
      {
        "title": "Imported Comic",
        "author": "Author A, Author B",
        "cover": "cover.png",
        "tags": {
          "题材": ["题材1", "题材2"],
          "年份": ["2025"],
          "语言": ["中文"],
          "状态": ["连载中"]
        }
      }
    ''');
    await _writeCbz(source, '第10话.cbz', {
      'Vol.10/002.jpg': [10, 2],
      'Vol.10/001.jpg': [10, 1],
    });
    await _writeCbz(source, '第2话.cbz', {
      'Vol.2/002.jpg': [2, 2],
      'Vol.2/001.jpg': [2, 1],
    });

    final comic = await const ImportComic()
        .checkArchiveChapterDirectoryForTesting(source);

    expect(comic, isNotNull);
    expect(comic!.title, 'Imported Comic');
    expect(comic.subtitle, 'Author A, Author B');
    expect(comic.chapters!.allChapters, {'第2话.cbz': '第2话', '第10话.cbz': '第10话'});
    expect(
      comic.tags,
      containsAll(['题材:题材1', '题材:题材2', '年份:2025', '语言:中文', '状态:连载中']),
    );

    final destination = Directory(comic.baseDir);
    expect(File('${destination.path}/cover.png').existsSync(), isTrue);
    expect(File('${destination.path}/info.json').existsSync(), isTrue);
    expect(File('${destination.path}/第2话.cbz').existsSync(), isTrue);
    expect(File('${destination.path}/第10话.cbz').existsSync(), isTrue);
    expect(Directory('${destination.path}/第2话.cbz').existsSync(), isFalse);

    final pages = await LocalCbzReader.listImageReferences(
      '${destination.path}/第2话.cbz',
    );
    expect(pages, hasLength(2));
    expect(pages, everyElement(startsWith('localcbz://')));
    expect(await LocalCbzReader.readReference(pages.first), [2, 1]);
    expect(await LocalCbzReader.readReference(pages.last), [2, 2]);
  });

  test('generates a cover but keeps the chapter archive intact', () async {
    final sourceArchive = await _writeCbz(source, '第1话.cbz', {
      '001.webp': [1, 2, 3],
      '002.webp': [4, 5, 6],
    });

    final comic = await const ImportComic()
        .checkArchiveChapterDirectoryForTesting(source);

    expect(comic, isNotNull);
    expect(comic!.title, source.name);
    expect(comic.cover, 'cover.webp');
    expect(File('${comic.baseDir}/cover.webp').readAsBytesSync(), [1, 2, 3]);
    expect(File('${comic.baseDir}/info.json').existsSync(), isFalse);
    expect(comic.chapters!.allChapters, {'第1话.cbz': '第1话'});
    final importedArchive = File('${comic.baseDir}/第1话.cbz');
    expect(importedArchive.existsSync(), isTrue);
    expect(importedArchive.readAsBytesSync(), sourceArchive.readAsBytesSync());
  });

  test('can read chapters in place without copying to local storage', () async {
    final info = File('${source.path}/info.json');
    await info.writeAsString('{"title":"In Place"}');
    final archive = await _writeCbz(source, '第1话.cbz', {
      '001.jpg': [1, 2, 3],
      '002.jpg': [4, 5, 6],
    });
    final importer = const ImportComic(copyToLocal: false);

    final comic = await importer.checkArchiveChapterDirectoryForTesting(source);

    expect(comic, isNotNull);
    expect(comic!.baseDir, source.path);
    expect(comic.title, 'In Place');
    expect(File('${source.path}/info.json').existsSync(), isTrue);
    expect(
      File('${source.path}/第1话.cbz').readAsBytesSync(),
      archive.readAsBytesSync(),
    );
    final pages = await LocalCbzReader.listImageReferences(archive.path);
    expect(await LocalCbzReader.readReference(pages.first), [1, 2, 3]);
    expect(Directory(LocalManager().path).listSync(), isEmpty);
  });

  test('ordinary directory import does not absorb archive chapters', () async {
    await File('${source.path}/cover.jpg').writeAsBytes([0]);
    await _writeCbz(source, '第1话.cbz', {
      '001.jpg': [1],
    });

    final comic = await const ImportComic().checkSingleComicForTesting(source);

    expect(comic, isNull);
  });

  test('rejects chapter folders in an archive chapter directory', () async {
    final chapter = await Directory('${source.path}/第1话').create();
    await File('${chapter.path}/001.jpg').writeAsBytes([1]);
    await _writeCbz(source, '第2话.cbz', {
      '001.jpg': [2],
    });

    expect(
      const ImportComic().checkArchiveChapterDirectoryForTesting(source),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('cannot contain chapter folders'),
        ),
      ),
    );
  });

  test('rejects 7z chapters in direct-read mode', () async {
    await File('${source.path}/第1话.7z').writeAsBytes([1]);

    expect(
      const ImportComic().checkArchiveChapterDirectoryForTesting(source),
      throwsA(
        predicate(
          (error) => error.toString().contains('supports CBZ and ZIP only'),
        ),
      ),
    );
  });
}

Future<File> _writeCbz(
  Directory directory,
  String name,
  Map<String, List<int>> entries,
) async {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  final bytes = ZipEncoder().encodeBytes(archive);
  return File('${directory.path}/$name').writeAsBytes(bytes);
}
