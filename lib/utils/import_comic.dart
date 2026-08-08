import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/pages/webdav_comics/comic_info.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/local_cbz.dart';
import 'package:venera/utils/natural_sort.dart';
import 'package:venera/utils/translations.dart';
import 'cbz.dart';
import 'io.dart';

class ImportComic {
  static const _coverBaseNames = {'cover', 'folder', 'thumb', '封面'};
  static const _archiveExtensions = {'cbz', 'zip', '7z', 'cb7'};
  static const _directReadArchiveExtensions = {'cbz', 'zip'};
  static const _imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'};

  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  Future<bool> cbz() async {
    var file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    Map<String?, List<LocalComic>> imported = {};
    if (file == null) {
      return false;
    }
    if (!App.rootContext.mounted) return false;
    var controller = showLoadingDialog(App.rootContext, allowCancel: false);
    try {
      var comic = await CBZ.import(File(file.path));
      imported[selectedFolder] = [comic];
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      if (App.rootContext.mounted) {
        App.rootContext.showMessage(message: e.toString());
      }
    }
    controller.close();
    return registerComics(imported, false);
  }

  Future<bool> multipleCbz() async {
    var picker = DirectoryPicker();
    var dir = await picker.pickDirectory(directAccess: true);
    if (dir != null) {
      var files = (await dir.list().toList()).whereType<File>().toList();
      files.removeWhere(
        (file) => !_archiveExtensions.contains(file.extension.toLowerCase()),
      );
      Map<String?, List<LocalComic>> imported = {};
      if (!App.rootContext.mounted) return false;
      var controller = showLoadingDialog(App.rootContext, allowCancel: false);
      var comics = <LocalComic>[];
      for (var file in files) {
        try {
          var comic = await CBZ.import(file);
          comics.add(comic);
        } catch (e, s) {
          Log.error("Import Comic", e.toString(), s);
        }
      }
      if (comics.isEmpty) {
        if (!App.rootContext.mounted) return false;
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
      imported[selectedFolder] = comics;
      controller.close();
      return registerComics(imported, false);
    }
    return false;
  }

  /// Import one comic directory whose archive files are chapters.
  ///
  /// The cover and `info.json` are optional. CBZ/ZIP chapters are copied into
  /// the app local path without extraction and read directly on demand.
  Future<bool> archiveChapterDirectory() async {
    final picker = DirectoryPicker();
    final directory = await picker.pickDirectory();
    if (directory == null) return false;

    if (!App.rootContext.mounted) return false;
    final controller = showLoadingDialog(App.rootContext, allowCancel: false);
    try {
      final comic = await _checkArchiveChapterDirectory(directory);
      if (comic == null) {
        if (App.rootContext.mounted) {
          App.rootContext.showMessage(message: 'Invalid Comic'.tl);
        }
        return false;
      }
      return registerComics({
        selectedFolder: [comic],
      }, copyToLocal);
    } catch (e, s) {
      Log.error('Import Comic', e.toString(), s);
      if (App.rootContext.mounted) {
        App.rootContext.showMessage(message: e.toString());
      }
      return false;
    } finally {
      controller.close();
    }
  }

  Future<bool> ehViewer() async {
    var dbFile = await selectFile(ext: ['db']);
    final picker = DirectoryPicker();
    final comicSrc = await picker.pickDirectory();
    Map<String?, List<LocalComic>> imported = {};
    if (dbFile == null || comicSrc == null) {
      return false;
    }

    bool cancelled = false;
    if (!App.rootContext.mounted) return false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );

    try {
      var db = sql.sqlite3.open(dbFile.path);

      Future<List<LocalComic>> validateComics(List<sql.Row> comics) async {
        List<LocalComic> imported = [];
        for (var comic in comics) {
          if (cancelled) {
            return imported;
          }
          var comicDir = Directory(
            FilePath.join(comicSrc.path, comic['DIRNAME'] as String),
          );
          String titleJP = comic['TITLE_JPN'] == null
              ? ""
              : comic['TITLE_JPN'] as String;
          String title = titleJP == "" ? comic['TITLE'] as String : titleJP;
          int timeStamp = comic['TIME'] as int;
          DateTime downloadTime = timeStamp != 0
              ? DateTime.fromMillisecondsSinceEpoch(timeStamp)
              : DateTime.now();
          var comicObj = await _checkSingleComic(
            comicDir,
            title: title,
            tags: [_categoryToString(comic['CATEGORY'] as int? ?? 0)],
            createTime: downloadTime,
          );
          if (comicObj == null) {
            continue;
          }
          imported.add(comicObj);
        }
        return imported;
      }

      var tags = <String>[""];
      tags.addAll(
        db
            .select("""
            SELECT * FROM DOWNLOAD_LABELS LB
            ORDER BY  LB.TIME DESC;
          """)
            .map((r) => r['LABEL'] as String)
            .toList(),
      );

      for (var tag in tags) {
        if (cancelled) {
          break;
        }
        var folderName = tag == '' ? '(EhViewer)Default'.tl : '(EhViewer)$tag';
        var comicList = db.select("""
              SELECT * 
              FROM DOWNLOAD_DIRNAME DN
              LEFT JOIN DOWNLOADS DL
              ON DL.GID = DN.GID
              WHERE DL.LABEL ${tag == '' ? 'IS NULL' : '= \'$tag\''} AND DL.STATE = 3
              ORDER BY DL.TIME DESC
            """).toList();

        var validComics = await validateComics(comicList);
        imported[folderName] = validComics;
        if (validComics.isNotEmpty &&
            !LocalFavoritesManager().existsFolder(folderName)) {
          LocalFavoritesManager().createFolder(folderName);
        }
      }
      db.dispose();

      //Android specific
      var cache = FilePath.join(App.cachePath, dbFile.name);
      await File(cache).deleteIgnoreError();
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      if (App.rootContext.mounted) {
        App.rootContext.showMessage(message: e.toString());
      }
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, copyToLocal);
  }

  Future<bool> directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) {
      return false;
    }
    Map<String?, List<LocalComic>> imported = {selectedFolder: []};
    try {
      if (single) {
        var result = await _checkSingleComic(path);
        if (result != null) {
          imported[selectedFolder]!.add(result);
        } else {
          if (!App.rootContext.mounted) return false;
          App.rootContext.showMessage(message: "Invalid Comic".tl);
          return false;
        }
      } else {
        await for (var entry in path.list()) {
          if (entry is Directory) {
            var result = await _checkSingleComic(entry);
            if (result != null) {
              imported[selectedFolder]!.add(result);
            }
          }
        }
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      if (App.rootContext.mounted) {
        App.rootContext.showMessage(message: e.toString());
      }
    }
    return registerComics(imported, copyToLocal);
  }

  Future<LocalComic?> _checkArchiveChapterDirectory(
    Directory directory, {
    bool checkDuplicate = true,
  }) async {
    if (!await directory.exists()) return null;
    final info = await ComicInfo.fromFile(
      File(FilePath.join(directory.path, 'info.json')),
    );
    final title = info?.title?.trim().isNotEmpty == true
        ? info!.title!.trim()
        : directory.name;
    if (checkDuplicate && LocalManager().findByName(title) != null) {
      Log.info('Import Comic', 'Comic already exists: $title');
      return null;
    }

    final archives = <File>[];
    await for (final entry in directory.list()) {
      if (entry is Directory) {
        if (entry.name.startsWith('.') || entry.name == '__MACOSX') continue;
        throw Exception(
          'Archive chapter directories cannot contain chapter folders.',
        );
      }
      if (entry is File &&
          _directReadArchiveExtensions.contains(
            entry.extension.toLowerCase(),
          )) {
        archives.add(entry);
      } else if (entry is File &&
          _archiveExtensions.contains(entry.extension.toLowerCase())) {
        throw Exception(
          'Direct archive chapter reading supports CBZ and ZIP only.',
        );
      }
    }
    if (archives.isEmpty) {
      throw Exception('No archive chapters found.');
    }
    return _importArchiveDirectory(
      directory,
      archives,
      info: info,
      title: title,
      copyToLocal: copyToLocal,
    );
  }

  Future<bool> localDownloads() async {
    var localDir = LocalManager().directory;
    Map<String?, List<LocalComic>> imported = {null: []};
    bool cancelled = false;
    if (!App.rootContext.mounted) return false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );
    try {
      if (!await localDir.exists()) {
        if (!App.rootContext.mounted) return false;
        App.rootContext.showMessage(message: "Local path not found".tl);
        controller.close();
        return false;
      }
      await for (var entry in localDir.list()) {
        if (cancelled) {
          break;
        }
        if (entry is Directory) {
          var stat = await entry.stat();
          var result = await _checkSingleComic(
            entry,
            createTime: stat.modified,
            useRelativePath: true,
          );
          if (result != null) {
            imported[null]!.add(result);
          }
        }
      }
      if (!cancelled && imported[null]!.isEmpty) {
        if (!App.rootContext.mounted) return false;
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      if (!App.rootContext.mounted) return false;
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, false);
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(
    Directory directory, {
    String? id,
    String? title,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
    bool checkDuplicate = true,
  }) async {
    if (!(await directory.exists())) return null;
    final info = await ComicInfo.fromFile(
      File(FilePath.join(directory.path, 'info.json')),
    );
    var name =
        title ??
        (info?.title?.trim().isNotEmpty == true
            ? info!.title!.trim()
            : directory.name);
    if (checkDuplicate && LocalManager().findByName(name) != null) {
      Log.info("Import Comic", "Comic already exists: $name");
      return null;
    }
    bool hasChapters = false;
    var chapters = <String>[];
    var coverPath = ''; // relative path to the cover image
    var fileList = <String>[];
    var archiveFiles = <File>[];
    await for (var entry in directory.list()) {
      if (entry is Directory) {
        if (entry.name.startsWith('.') || entry.name == '__MACOSX') continue;
        hasChapters = true;
        chapters.add(entry.name);
        await for (var file in entry.list()) {
          if (file is Directory) {
            Log.info(
              "Import Comic",
              "Invalid Chapter: ${entry.name}\nA directory is found in the chapter directory.",
            );
            return null;
          }
        }
      } else if (entry is File) {
        final extension = entry.extension.toLowerCase();
        if (_imageExtensions.contains(extension)) {
          fileList.add(entry.name);
        } else if (_archiveExtensions.contains(extension)) {
          archiveFiles.add(entry);
        }
      }
    }

    if (archiveFiles.isNotEmpty) {
      Log.info(
        'Import Comic',
        'Archive chapters require the dedicated archive chapter import.',
      );
      return null;
    }

    if (fileList.isEmpty && !hasChapters) {
      return null;
    }

    fileList.sort(naturalCompare);
    if (fileList.isNotEmpty) {
      coverPath = fileList.firstWhereOrNull(_isCoverFileName) ?? fileList.first;
    }

    chapters.sort(naturalCompare);
    if (hasChapters && coverPath == '') {
      // use the first image in the first chapter as the cover
      final firstChapter = Directory(
        FilePath.join(directory.path, chapters.first),
      );
      final images =
          firstChapter
              .listSync()
              .whereType<File>()
              .where(
                (file) =>
                    _imageExtensions.contains(file.extension.toLowerCase()),
              )
              .toList()
            ..sort((a, b) => naturalCompare(a.name, b.name));
      if (images.isNotEmpty) {
        coverPath = FilePath.join(chapters.first, images.first.name);
      }
    }
    if (coverPath == '') {
      Log.info("Import Comic", "Invalid Comic: $name\nNo cover image found.");
      return null;
    }
    var directoryPath = useRelativePath ? directory.name : directory.path;
    return LocalComic(
      id: id ?? '0',
      title: name,
      subtitle: subtitle ?? _infoAuthor(info),
      tags: tags ?? _infoTags(info),
      directory: directoryPath,
      chapters: hasChapters
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: coverPath,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime ?? DateTime.now(),
    );
  }

  @visibleForTesting
  Future<LocalComic?> checkSingleComicForTesting(Directory directory) {
    return _checkSingleComic(directory, checkDuplicate: false);
  }

  @visibleForTesting
  Future<LocalComic?> checkArchiveChapterDirectoryForTesting(
    Directory directory,
  ) {
    return _checkArchiveChapterDirectory(directory, checkDuplicate: false);
  }

  static String _infoAuthor(ComicInfo? info) => info?.author?.trim() ?? '';

  Future<LocalComic> _importArchiveDirectory(
    Directory source,
    List<File> archives, {
    required ComicInfo? info,
    required String title,
    required bool copyToLocal,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
  }) async {
    archives.sort((a, b) => naturalCompare(a.name, b.name));
    final destinationName = copyToLocal
        ? findValidDirectoryName(LocalManager().path, title)
        : source.path;
    final destination = copyToLocal
        ? Directory(FilePath.join(LocalManager().path, destinationName))
        : source;
    if (copyToLocal) await destination.create(recursive: true);

    try {
      final cover = _findCoverFile(source, info?.cover);
      String? coverName;
      if (cover != null) {
        if (copyToLocal) {
          coverName = 'cover.${cover.extension.toLowerCase()}';
          await cover.copyMem(FilePath.join(destination.path, coverName));
        } else {
          coverName = cover.path.substring(source.path.length + 1);
        }
      }

      final chapterMap = <String, String>{};
      for (var index = 0; index < archives.length; index++) {
        final sourceArchive = archives[index];
        final chapterFileName = sourceArchive.name;
        final destinationArchive = copyToLocal
            ? File(FilePath.join(destination.path, chapterFileName))
            : sourceArchive;
        if (copyToLocal) {
          await _copyArchiveToCache(sourceArchive, destinationArchive);
        }

        final images = await LocalCbzReader.listImages(destinationArchive.path);
        if (images.isEmpty) {
          throw Exception('No images found in ${archives[index].name}');
        }
        if (coverName == null) {
          final coverEntry =
              images.firstWhereOrNull(
                (entry) => _coverBaseNames.contains(
                  _archiveEntryBaseName(entry.fileName).toLowerCase(),
                ),
              ) ??
              images.first;
          final extension = _archiveEntryExtension(coverEntry.fileName);
          coverName = 'cover.$extension';
          final bytes = await LocalCbzReader.readEntry(
            destinationArchive.path,
            coverEntry.fileName,
          );
          await File(
            FilePath.join(destination.path, coverName),
          ).writeAsBytes(bytes);
        }
        chapterMap[chapterFileName] = _archiveDisplayName(chapterFileName);
      }

      final sourceInfo = File(FilePath.join(source.path, 'info.json'));
      if (copyToLocal && await sourceInfo.exists()) {
        final destinationInfo = File(
          FilePath.join(destination.path, 'info.json'),
        );
        final rawInfo = await sourceInfo.readAsString();
        try {
          final decoded = jsonDecode(rawInfo);
          if (decoded is Map) {
            final json = Map<String, dynamic>.from(decoded);
            json['cover'] = coverName;
            await destinationInfo.writeAsString(jsonEncode(json));
          } else {
            await destinationInfo.writeAsString(rawInfo);
          }
        } on FormatException {
          await destinationInfo.writeAsString(rawInfo);
        }
      }

      return LocalComic(
        id: '0',
        title: title,
        subtitle: subtitle ?? _infoAuthor(info),
        tags: tags ?? _infoTags(info),
        directory: destinationName,
        chapters: ComicChapters(chapterMap),
        cover: coverName!,
        comicType: ComicType.local,
        downloadedChapters: chapterMap.keys.toList(),
        createdAt: createTime ?? DateTime.now(),
      );
    } catch (_) {
      if (copyToLocal) {
        await destination.deleteIgnoreError(recursive: true);
      }
      rethrow;
    }
  }

  static File? _findCoverFile(Directory directory, String? configuredCover) {
    if (configuredCover != null && configuredCover.trim().isNotEmpty) {
      final value = configuredCover.trim();
      if (!value.startsWith('http://') &&
          !value.startsWith('https://') &&
          !value.startsWith('file://')) {
        final file = File(
          FilePath.join(
            directory.path,
            value.startsWith('/') ? value.substring(1) : value,
          ),
        );
        if (file.existsSync()) return file;
      }
    }
    final images =
        directory
            .listSync()
            .whereType<File>()
            .where(
              (file) => _imageExtensions.contains(file.extension.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
    return images.firstWhereOrNull(
          (file) =>
              _coverBaseNames.contains(file.basenameWithoutExt.toLowerCase()),
        ) ??
        images.firstOrNull;
  }

  static bool _isCoverFileName(String name) {
    final dot = name.lastIndexOf('.');
    final base = (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
    return _coverBaseNames.contains(base);
  }

  static String _archiveDisplayName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String _archiveEntryExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'jpg';
    return name.substring(dot + 1).toLowerCase();
  }

  static String _archiveEntryBaseName(String name) {
    final leaf = name.replaceAll('\\', '/').split('/').last;
    final dot = leaf.lastIndexOf('.');
    return dot > 0 ? leaf.substring(0, dot) : leaf;
  }

  static Future<void> _copyArchiveToCache(File source, File destination) async {
    final input = await source.open();
    final output = await destination.open(mode: FileMode.write);
    try {
      final buffer = Uint8List(1024 * 1024);
      while (true) {
        final count = await input.readInto(buffer);
        if (count == 0) break;
        await output.writeFrom(buffer, 0, count);
      }
    } finally {
      await input.close();
      await output.close();
    }
  }

  static List<String> _infoTags(ComicInfo? info) {
    if (info == null) return const [];
    return info.detailTags.entries
        .expand((entry) => entry.value.map((value) => '${entry.key}:$value'))
        .toList();
  }

  static Future<Map<String, String>> _copyDirectories(
    Map<String, dynamic> data,
  ) async {
    return overrideIO(() async {
      var toBeCopied = data['toBeCopied'] as List<String>;
      var destination = data['destination'] as String;
      Map<String, String> result = {};
      for (var dir in toBeCopied) {
        var source = Directory(dir);
        var dest = Directory("$destination/${source.name}");
        if (dest.existsSync()) {
          // The destination directory already exists, and it is not managed by the app.
          // Rename the old directory to avoid conflicts.
          Log.info(
            "Import Comic",
            "Directory already exists: ${source.name}\nRenaming the old directory.",
          );
          dest.renameSync(
            findValidDirectoryName(dest.parent.path, "${dest.path}_old"),
          );
        }
        dest.createSync();
        await copyDirectory(source, dest);
        result[source.path] = dest.path;
      }
      return result;
    });
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
    Map<String?, List<LocalComic>> comics,
  ) async {
    var destPath = LocalManager().path;
    final normalizedDest = destPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    bool isManaged(LocalComic comic) {
      final base = comic.baseDir
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      return base == normalizedDest || base.startsWith('$normalizedDest/');
    }

    Map<String?, List<LocalComic>> result = {};
    for (var favoriteFolder in comics.keys) {
      result[favoriteFolder] = comics[favoriteFolder]!
          .where(isManaged)
          .toList();
      comics[favoriteFolder]!.removeWhere(isManaged);

      if (comics[favoriteFolder]!.isEmpty) {
        continue;
      }

      try {
        // copy the comics to the local directory
        final pathMap =
            await compute<Map<String, dynamic>, Map<String, String>>(
              _copyDirectories,
              {
                'toBeCopied': comics[favoriteFolder]!
                    .map((e) => e.directory)
                    .toList(),
                'destination': destPath,
              },
            );
        //Construct a new object since LocalComic.directory is a final String
        for (var c in comics[favoriteFolder]!) {
          result[favoriteFolder]!.add(
            LocalComic(
              id: c.id,
              title: c.title,
              subtitle: c.subtitle,
              tags: c.tags,
              directory: pathMap[c.directory]!,
              chapters: c.chapters,
              cover: c.cover,
              comicType: c.comicType,
              downloadedChapters: c.downloadedChapters,
              createdAt: c.createdAt,
            ),
          );
        }
      } catch (e, s) {
        if (!App.rootContext.mounted) return result;
        App.rootContext.showMessage(message: "Failed to copy comics".tl);
        Log.error("Import Comic", e.toString(), s);
        return result;
      }
    }
    return result;
  }

  Future<bool> registerComics(
    Map<String?, List<LocalComic>> importedComics,
    bool copy,
  ) async {
    try {
      if (copy) {
        importedComics = await _copyComicsToLocalDir(importedComics);
      }
      int importedCount = 0;
      for (var folder in importedComics.keys) {
        for (var comic in importedComics[folder]!) {
          var id = LocalManager().findValidId(ComicType.local);
          LocalManager().add(comic, id);
          importedCount++;
          if (folder != null) {
            LocalFavoritesManager().addComic(
              folder,
              FavoriteItem(
                id: id,
                name: comic.title,
                coverPath: comic.cover,
                author: comic.subtitle,
                type: comic.comicType,
                tags: comic.tags,
                favoriteTime: comic.createdAt,
              ),
            );
          }
        }
      }
      if (!App.rootContext.mounted) return true;
      App.rootContext.showMessage(
        message: "Imported @a comics".tlParams({'a': importedCount}),
      );
    } catch (e, s) {
      if (!App.rootContext.mounted) return false;
      App.rootContext.showMessage(message: "Failed to register comics".tl);
      Log.error("Import Comic", e.toString(), s);
      return false;
    }
    return true;
  }

  /// Convert EhViewer CATEGORY bit flag to string.
  /// Standard categories are bit flags (1,2,4,...,512),
  /// plus 0x400 (PRIVATE) and 0x800 (UNKNOWN).
  static String _categoryToString(int category) {
    const map = {
      0x1: 'MISC',
      0x2: 'DOUJINSHI',
      0x4: 'MANGA',
      0x8: 'ARTISTCG',
      0x10: 'GAMECG',
      0x20: 'IMAGE SET',
      0x40: 'COSPLAY',
      0x80: 'ASIAN PORN',
      0x100: 'NON-H',
      0x200: 'WESTERN',
      0x400: 'PRIVATE',
      0x800: 'UNKNOWN',
    };
    return map[category] ?? 'UNKNOWN';
  }
}
