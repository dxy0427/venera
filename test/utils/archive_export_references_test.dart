import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';

void main() {
  test('PDF and EPUB collect direct-read archive pages', () async {
    final root = await Directory.systemTemp.createTemp('archive-export-');
    addTearDown(() => root.delete(recursive: true));
    LocalManager().path = root.path;
    final comicDir = await Directory('${root.path}/comic').create();
    await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
    await _writeCbz(File('${comicDir.path}/chapter.cbz'), {
      'nested/001.jpg': [1, 2],
      'nested/002.png': [3, 4],
    });
    final comic = LocalComic(
      id: 'archive',
      title: 'Archive',
      subtitle: '',
      tags: const [],
      directory: 'comic',
      chapters: const ComicChapters({'chapter.cbz': 'Chapter'}),
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const ['chapter.cbz'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final pdfImages = await listPdfImagesForTesting(comic, root.path);
    final epubImages = await collectEpubImages(comic);

    expect(pdfImages.first, '${comicDir.path}/cover.jpg');
    expect(pdfImages.skip(1), hasLength(2));
    expect(pdfImages.skip(1), everyElement(startsWith('localcbz://')));
    expect(epubImages.map((chapter) => chapter.title), ['Chapter']);
    expect(epubImages.single.images.map((image) => image.extension), [
      'jpg',
      'png',
    ]);
    expect(await epubImages.single.images[0].readAsBytes(), [1, 2]);
    expect(await epubImages.single.images[1].readAsBytes(), [3, 4]);
  });

  test('EPUB keeps chapters with duplicate display names', () async {
    final root = await Directory.systemTemp.createTemp('archive-epub-');
    addTearDown(() => root.delete(recursive: true));
    LocalManager().path = root.path;
    final comicDir = await Directory('${root.path}/comic').create();
    await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
    await _writeCbz(File('${comicDir.path}/01.cbz'), {
      '001.jpg': [1],
    });
    await _writeCbz(File('${comicDir.path}/01.zip'), {
      '001.jpg': [2],
    });
    final comic = LocalComic(
      id: 'duplicate-title',
      title: 'Archive',
      subtitle: '',
      tags: const [],
      directory: 'comic',
      chapters: const ComicChapters({'01.cbz': '01', '01.zip': '01'}),
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const ['01.cbz', '01.zip'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final chapters = await collectEpubImages(comic);

    expect(chapters, hasLength(2));
    expect(await chapters[0].images.single.readAsBytes(), [1]);
    expect(await chapters[1].images.single.readAsBytes(), [2]);
  });
}

Future<void> _writeCbz(File file, Map<String, List<int>> entries) async {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
}
