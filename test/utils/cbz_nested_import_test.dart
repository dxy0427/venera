import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory local;
  late Directory cache;
  final realExtractor = CBZ.extractor;

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
    CBZ.extractor = realExtractor;
    await root.delete(recursive: true);
  });

  test('collectImages keeps nested archive folders contiguous', () async {
    final extracted = await Directory('${root.path}/extracted').create();
    await Directory('${extracted.path}/Vol.10').create();
    await Directory('${extracted.path}/Vol.2').create();
    await File('${extracted.path}/Vol.10/001.jpg').writeAsBytes([10]);
    await File('${extracted.path}/Vol.2/010.jpg').writeAsBytes([2, 10]);
    await File('${extracted.path}/Vol.2/002.jpg').writeAsBytes([2, 2]);

    final relative = CBZ
        .collectImages(extracted)
        .map((file) => file.path.substring(extracted.path.length + 1))
        .toList();

    expect(relative, ['Vol.2/002.jpg', 'Vol.2/010.jpg', 'Vol.10/001.jpg']);
  });

  test('imports cover, info.json and multiple CBZ files as chapters', () async {
    await File('${source.path}/cover.png').writeAsBytes([0]);
    await File('${source.path}/info.json').writeAsString('''
      {
        "title": "Imported Comic",
        "author": "Author A, Author B",
        "cover": "cover.png",
        "tags": {
          "画师": ["Hidden Artist"],
          "题材": ["Drama"],
          "年份": ["2024"],
          "语言": ["中文"]
        }
      }
    ''');
    await File('${source.path}/第10话.cbz').writeAsBytes([10]);
    await File('${source.path}/第2话.cbz').writeAsBytes([2]);

    CBZ.extractor = (archive, out) async {
      final folder = archive.name.contains('2') ? 'Vol.2' : 'Vol.10';
      final nested = await Directory(
        '${out.path}/$folder',
      ).create(recursive: true);
      await File('${nested.path}/002.jpg').writeAsBytes([2]);
      await File('${nested.path}/001.jpg').writeAsBytes([1]);
    };

    final comic = await const ImportComic().checkSingleComicForTesting(source);

    expect(comic, isNotNull);
    expect(comic!.title, 'Imported Comic');
    expect(comic.subtitle, 'Author A, Author B');
    expect(comic.chapters!.allChapters, {'0': '第2话', '1': '第10话'});
    expect(
      comic.tags,
      containsAll([
        'Author:Author A',
        'Author:Author B',
        'Genre:Drama',
        'Year:2024',
        'Language:中文',
      ]),
    );
    expect(comic.tags.any((tag) => tag.contains('Hidden Artist')), isFalse);

    final destination = Directory(comic.baseDir);
    expect(File('${destination.path}/cover.png').existsSync(), isTrue);
    expect(File('${destination.path}/info.json').existsSync(), isTrue);
    expect(
      await File('${destination.path}/info.json').readAsString(),
      contains('"cover":"cover.png"'),
    );
    final firstChapter = Directory(
      '${destination.path}/0',
    ).listSync().map((e) => e.name).toList()..sort();
    final secondChapter = Directory(
      '${destination.path}/1',
    ).listSync().map((e) => e.name).toList()..sort();
    expect(firstChapter, ['0001.jpg', '0002.jpg']);
    expect(secondChapter, ['0001.jpg', '0002.jpg']);
  });

  test('rejects a directory that mixes chapter folders and archives', () async {
    await File('${source.path}/cover.jpg').writeAsBytes([0]);
    final chapter = await Directory('${source.path}/第1话').create();
    await File('${chapter.path}/001.jpg').writeAsBytes([1]);
    await File('${source.path}/第2话.cbz').writeAsBytes([2]);

    expect(
      const ImportComic().checkSingleComicForTesting(source),
      throwsA(
        predicate(
          (error) => error.toString().contains('cannot mix chapter folders'),
        ),
      ),
    );
  });
}
