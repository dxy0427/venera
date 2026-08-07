import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/webdav_comics/comic_info.dart';
import 'package:venera/utils/io.dart';

class LocalBuiltinSource {
  LocalBuiltinSource._();

  static const key = 'local';
  static const name = 'Local';

  static final ComicSource source = create();

  static ComicSource create() {
    return ComicSource(
      name,
      key,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      loadComicInfo,
      null,
      loadComicPages,
      null,
      null,
      'builtin:local',
      '',
      '1.0.0',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      {
        'zh_CN': {
          'Local': '本地',
          'Author': '作者',
          'Genre': '题材',
          'Genres': '题材',
          'Year': '年份',
          'Language': '语言',
          'Status': '状态',
          'Tags': '标签',
        },
        'zh_TW': {
          'Local': '本地',
          'Author': '作者',
          'Genre': '題材',
          'Genres': '題材',
          'Year': '年份',
          'Language': '語言',
          'Status': '狀態',
          'Tags': '標籤',
        },
        'en_US': {
          'Local': 'Local',
          'Author': 'Author',
          'Genre': 'Genre',
          'Genres': 'Genres',
          'Year': 'Year',
          'Language': 'Language',
          'Status': 'Status',
          'Tags': 'Tags',
        },
      },
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  static Future<Res<ComicDetails>> loadComicInfo(String id) async {
    try {
      final localComic = LocalManager().find(id, ComicType.local);
      if (localComic == null) {
        return const Res.error('Local comic not found');
      }

      ComicInfo? info;
      final infoFile = File(FilePath.join(localComic.baseDir, 'info.json'));
      if (await infoFile.exists()) {
        info = await ComicInfo.fromFile(infoFile);
      }

      final storedTags = <String, List<String>>{};
      for (final tag in localComic.tags) {
        final separator = tag.indexOf(':');
        if (separator <= 0) continue;
        final namespace = tag.substring(0, separator);
        final value = tag.substring(separator + 1);
        storedTags.putIfAbsent(namespace, () => []).add(value);
      }
      final storedDetailTags = ComicInfo(tags: storedTags).detailTags
        ..remove('Author');
      final infoDetailTags = info?.detailTags ?? const <String, List<String>>{};
      // Prefer live info.json, fall back to stored import tags; keep info order.
      final tags = <String, List<String>>{
        for (final entry in infoDetailTags.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value,
      };
      for (final entry in storedDetailTags.entries) {
        tags.putIfAbsent(entry.key, () => entry.value);
      }

      final title = (info?.title?.trim().isNotEmpty == true)
          ? info!.title!.trim()
          : localComic.title;

      String cover = 'file://${localComic.coverFile.path}';
      if (info?.cover != null && info!.cover!.trim().isNotEmpty) {
        final c = info.cover!.trim();
        if (c.startsWith('http') || c.startsWith('file://')) {
          cover = c;
        } else {
          final coverPath = FilePath.join(
            localComic.baseDir,
            c.startsWith('/') ? c.substring(1) : c,
          );
          cover = 'file://$coverPath';
        }
      }

      var updateTime = info?.updateTime?.trim();
      if (updateTime == null || updateTime.isEmpty) {
        final modified = await _latestModifiedDate(localComic.baseDir);
        updateTime = modified;
      }

      final json = <String, dynamic>{
        'title': title,
        'subtitle': info?.author?.trim().isNotEmpty == true
            ? info!.author!.trim()
            : null,
        'cover': cover,
        'description': info?.description ?? localComic.description,
        'tags': tags,
        'chapters': localComic.chapters?.toJson(),
        'sourceKey': key,
        'comicId': id,
        'stars': info?.stars,
        'maxPage': null,
        'updateTime': (updateTime?.isEmpty ?? true) ? null : updateTime,
        'uploadTime': null,
      };
      return Res(ComicDetails.fromJson(json));
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// Latest modification date inside the comic directory, `YYYY-MM-DD`.
  static Future<String?> _latestModifiedDate(String baseDir) async {
    try {
      final dir = Directory(baseDir);
      if (!await dir.exists()) return null;
      DateTime? latest;
      await for (final entity in dir.list()) {
        if (entity is File) {
          final extension = entity.extension.toLowerCase();
          if (!const {
            'jpg',
            'jpeg',
            'png',
            'webp',
            'gif',
            'jpe',
            'bmp',
            'tiff',
            'tif',
            'avif',
            'cbz',
            'zip',
            '7z',
            'cb7',
          }.contains(extension)) {
            continue;
          }
          final lower = entity.name.toLowerCase();
          if (lower.startsWith('cover.') ||
              lower.startsWith('folder.') ||
              lower.startsWith('thumb.') ||
              lower.startsWith('封面.')) {
            continue;
          }
        }
        final stat = await entity.stat();
        final modified = stat.modified;
        if (latest == null || modified.isAfter(latest)) latest = modified;
      }
      if (latest == null) return null;
      final local = latest.toLocal();
      final month = local.month.toString().padLeft(2, '0');
      final day = local.day.toString().padLeft(2, '0');
      return '${local.year}-$month-$day';
    } catch (_) {
      return null;
    }
  }

  static Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    try {
      final localComic = LocalManager().find(id, ComicType.local);
      if (localComic == null) {
        return const Res.error('Local comic not found');
      }
      Object chapter = 1;
      if (localComic.chapters != null && localComic.chapters!.ids.isNotEmpty) {
        if (ep != null && ep.isNotEmpty && ep != '0') {
          chapter = ep;
        } else {
          chapter = localComic.chapters!.ids.first;
        }
      }
      final images = await LocalManager().getImages(
        id,
        ComicType.local,
        chapter,
      );
      return Res(images);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<bool> hasDetail(LocalComic comic) async {
    final infoFile = File(FilePath.join(comic.baseDir, 'info.json'));
    if (!await infoFile.exists()) return false;
    final info = await ComicInfo.fromFile(infoFile);
    return info != null && !info.isEmpty;
  }
}
