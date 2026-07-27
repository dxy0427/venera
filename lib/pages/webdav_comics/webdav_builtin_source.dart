import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

import 'webdav_client.dart';
import 'webdav_models.dart';
import 'webdav_provider.dart';

/// Built-in WebDAV comic source (native Dart, not a JS config).
///
/// Appears like other sources in explore / comic source list, and drives the
/// standard [ComicPage] detail UI via [loadComicInfo] / [loadComicPages].
class WebDavBuiltinSource {
  WebDavBuiltinSource._();

  static const key = 'webdav';
  static const name = 'WebDAV';

  static ComicSource create() {
    return ComicSource(
      name,
      key,
      null, // account
      null, // categoryData
      null, // categoryComicsData
      null, // favoriteData
      [
        ExplorePageData(
          'WebDAV',
          ExplorePageType.multiPageComicList,
          (page) async {
            if (page > 1) {
              return const Res([], subData: 1);
            }
            if (!WebDavProvider().isConfigured) {
              return Res.error(
                'WebDAV not configured. Open settings to set server URL.'.tl,
              );
            }
            try {
              await WebDavProvider().loadComics(forceRefresh: true);
              final comics = WebDavProvider().comics ?? [];
              return Res(
                comics
                    .where((e) => !(e.isDirectory && e.isCategory))
                    .map(_toComic)
                    .toList(),
                subData: 1,
              );
            } catch (e) {
              return Res.error(e.toString());
            }
          },
          null,
          null,
          null,
        ),
      ],
      SearchPageData(
        null,
        (keyword, page, options) async {
          if (page > 1) {
            return const Res([], subData: 1);
          }
          if (!WebDavProvider().isConfigured) {
            return Res.error('WebDAV not configured'.tl);
          }
          try {
            await WebDavProvider().loadComics(forceRefresh: false);
            final all = WebDavProvider().comics ?? [];
            final kw = keyword.trim().toLowerCase();
            final filtered = all
                .where((e) => !(e.isDirectory && e.isCategory))
                .where((e) => kw.isEmpty || e.name.toLowerCase().contains(kw))
                .map(_toComic)
                .toList();
            return Res(filtered, subData: 1);
          } catch (e) {
            return Res.error(e.toString());
          }
        },
        null,
      ),
      null, // settings — use home card / dedicated page
      loadComicInfo,
      null, // loadComicThumbnail
      loadComicPages,
      null, // getImageLoadingConfig
      null, // getThumbnailLoadingConfig
      'builtin:webdav',
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
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  static Comic _toComic(WebDavComicEntry e) {
    final cover = e.coverPath == null
        ? ''
        : (e.coverPath!.startsWith('webdav://') ||
                e.coverPath!.startsWith('file://') ||
                e.coverPath!.startsWith('http')
            ? e.coverPath!
            : 'webdav://${e.coverPath}');
    return Comic(
      e.name,
      cover,
      e.path,
      null,
      const [],
      e.isDirectory ? 'Folder'.tl : 'Archive'.tl,
      key,
      null,
      null,
    );
  }

  /// Load comic details for standard ComicPage UI.
  static Future<Res<ComicDetails>> loadComicInfo(String id) async {
    try {
      final provider = WebDavProvider();
      if (!provider.isConfigured) {
        return Res.error('WebDAV not configured'.tl);
      }

      final path = id;
      final name = path.split('/').where((s) => s.isNotEmpty).last;
      final isDirectory = path.endsWith('/');

      // info.json metadata
      final info = isDirectory ? await provider.loadComicInfo(path) : null;

      // Cover
      String cover = '';
      if (info?.cover != null && info!.cover!.isNotEmpty) {
        final c = info.cover!;
        cover = c.startsWith('http') || c.startsWith('webdav://')
            ? c
            : 'webdav://${path}${c.startsWith('/') ? c.substring(1) : c}';
      } else {
        // Probe cover via a temporary entry
        final entry = WebDavComicEntry(
          name: name,
          path: path,
          isDirectory: isDirectory,
        );
        try {
          await WebDavComicClient().loadCover(entry);
          if (entry.coverPath != null) {
            cover = entry.coverPath!.startsWith('webdav://') ||
                    entry.coverPath!.startsWith('file://')
                ? entry.coverPath!
                : 'webdav://${entry.coverPath}';
          }
        } catch (_) {}
      }

      // Chapters or flat images
      ComicChapters? chapters;
      int? maxPage;
      if (isDirectory) {
        final chapterList = await provider.getChapters(path);
        if (chapterList.isNotEmpty) {
          final map = <String, String>{};
          for (final c in chapterList) {
            map[c.path] = c.name;
          }
          chapters = ComicChapters(map);
        } else {
          final images = await provider.getComicImages(path);
          maxPage = images.length;
        }
      } else {
        // Single archive — one synthetic chapter for cleaner UI, or flat
        final images = await provider.getComicImages(path);
        maxPage = images.length;
      }

      final tags = <String, List<String>>{};
      if (info != null && info.tags.isNotEmpty) {
        tags.addAll(info.tags);
      }
      if (info?.author != null && info!.author!.isNotEmpty) {
        tags.putIfAbsent('Author', () => [info.author!]);
      }

      final json = <String, dynamic>{
        'title': info?.title ?? name,
        'subtitle': info?.author,
        'cover': cover,
        'description': info?.description ?? '',
        'tags': tags,
        'chapters': chapters?.toJson(),
        'sourceKey': key,
        'comicId': path,
        'stars': info?.stars,
        'maxPage': maxPage,
        'updateTime': null,
        'uploadTime': null,
      };
      return Res(ComicDetails.fromJson(json));
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<String>>> loadComicPages(
    String id,
    String? ep,
  ) async {
    try {
      final provider = WebDavProvider();
      List<String> images;
      if (ep != null && ep.isNotEmpty && ep != '0') {
        images = await provider.getChapterImages(ep);
      } else {
        images = await provider.getComicImages(id);
      }
      return Res(images);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// Register into [ComicSourceManager] if not already present.
  static void register() {
    final manager = ComicSourceManager();
    if (manager.find(key) != null) return;
    final source = create();
    // Ensure explore page is enabled by default once
    final explorePages =
        List<String>.from(appdata.settings['explore_pages'] ?? []);
    if (!explorePages.contains('WebDAV')) {
      explorePages.add('WebDAV');
      appdata.settings['explore_pages'] = explorePages;
      // fire-and-forget save
      appdata.saveData(false);
    }
    manager.add(source);
  }
}
