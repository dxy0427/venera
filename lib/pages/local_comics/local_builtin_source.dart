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
        'zh_CN': {'Local': '本地', 'Author': '作者'},
        'zh_TW': {'Local': '本地', 'Author': '作者'},
        'en_US': {'Local': 'Local', 'Author': 'Author'},
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

      final tags = <String, List<String>>{};
      if (info != null && info.tags.isNotEmpty) {
        for (final e in info.tags.entries) {
          if (e.value.isNotEmpty) {
            tags[e.key] = List<String>.from(e.value);
          }
        }
      } else {
        for (final t in localComic.tags) {
          final i = t.indexOf(':');
          if (i > 0) {
            final ns = t.substring(0, i);
            final v = t.substring(i + 1);
            tags.putIfAbsent(ns, () => []).add(v);
          } else if (t.isNotEmpty) {
            tags.putIfAbsent('tag', () => []).add(t);
          }
        }
      }

      final author = info?.author?.trim();
      if (author != null && author.isNotEmpty) {
        final hasAuthorNs = tags.keys.any(
          (k) => const {
            'author',
            'authors',
            'artist',
            'artists',
            '作者',
            '画师',
          }.contains(k.toLowerCase()),
        );
        if (!hasAuthorNs) {
          tags['Author'] = [author];
        }
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

      final json = <String, dynamic>{
        'title': title,
        'subtitle': null,
        'cover': cover,
        'description': info?.description ?? localComic.description,
        'tags': tags,
        'chapters': localComic.chapters?.toJson(),
        'sourceKey': key,
        'comicId': id,
        'stars': info?.stars,
        'maxPage': null,
        'updateTime': null,
        'uploadTime': null,
      };
      return Res(ComicDetails.fromJson(json));
    } catch (e) {
      return Res.error(e.toString());
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
