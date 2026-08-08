import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_cbz.dart';

void main() {
  test('LocalManager returns direct-read archive page references', () async {
    final root = await Directory.systemTemp.createTemp('local-cbz-pages-');
    addTearDown(() => root.delete(recursive: true));
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await Directory(App.cachePath).create();
    final manager = LocalManager();
    manager.initForTesting(root.path);

    final comicDir = await Directory('${root.path}/comic').create();
    await _writeCbz(File('${comicDir.path}/chapter.cbz'), {
      '010.jpg': [10],
      '002.jpg': [2],
      '001.jpg': [1],
    });
    final comic = LocalComic(
      id: '1',
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
    await manager.add(comic);

    final images = await manager.getImages('1', ComicType.local, 'chapter.cbz');

    expect(images, hasLength(3));
    expect(images, everyElement(startsWith('localcbz://')));
    expect(await LocalCbzReader.readReference(images[0]), [1]);
    expect(await LocalCbzReader.readReference(images[1]), [2]);
    expect(await LocalCbzReader.readReference(images[2]), [10]);
    expect(manager.isDownloaded('1', ComicType.local, 1), isTrue);

    final favorite = ImageFavorite(
      2,
      images[1],
      null,
      'chapter.cbz',
      '1',
      1,
      'local',
      'Chapter',
    );
    expect(await ImageFavoritesProvider(favorite).getImageFromLocal(), [2]);
  });
}

Future<void> _writeCbz(File file, Map<String, List<int>> entries) async {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
}
