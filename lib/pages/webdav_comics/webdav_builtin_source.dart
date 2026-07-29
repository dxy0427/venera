import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

import 'comic_info.dart';
import 'webdav_client.dart';
import 'webdav_models.dart';
import 'webdav_provider.dart';
import 'webdav_settings_page.dart';

/// Built-in WebDAV comic source (native Dart, not a JS config).
///
/// Appears like other sources in explore / comic source list, and drives the
/// standard [ComicPage] detail UI via [loadComicInfo] / [loadComicPages].
class WebDavBuiltinSource {
  WebDavBuiltinSource._();

  static const key = 'webdav';

  /// English base name; UI should use `.tl` / source [translations].
  static const name = 'WebDAV';

  static const exploreTitle = 'WebDAV Comics';

  static ComicSource create() {
    final settings = <String, Map<String, dynamic>>{
      'accounts': {
        'title': 'Accounts',
        'type': 'callback',
        'buttonText': 'Manage',
        'callback': (List args) {
          return App.rootContext.to(() => const WebDavSettingsPage());
        },
      },
    };
    return ComicSource(
      name,
      key,
      null, // account
      null, // categoryData
      null, // categoryComicsData
      null, // favoriteData
      [
        ExplorePageData(
          exploreTitle,
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
              final provider = WebDavProvider();
              await provider.loadComics(forceRefresh: false);
              final comics = provider.comics ?? [];
              final readable = comics
                  .where((e) => !(e.isDirectory && e.isCategory))
                  .toList();
              // Resolve cover paths before building list items so explore
              // can load thumbnails (stream:// for cbz, webdav:// for dirs).
              await provider.ensureCoverPaths(readable);
              final list = await provider.runBatches(
                readable.map(
                  (e) =>
                      () => _toComicAsync(e),
                ),
              );
              list.sort(
                (a, b) =>
                    a.title.toLowerCase().compareTo(b.title.toLowerCase()),
              );
              return Res(list, subData: 1);
            } catch (e) {
              return Res.error(e.toString());
            }
          },
          null,
          null,
          null,
        ),
      ],
      SearchPageData(null, (keyword, page, options) async {
        if (page > 1) {
          return const Res([], subData: 1);
        }
        if (!WebDavProvider().isConfigured) {
          return Res.error('WebDAV not configured'.tl);
        }
        try {
          final provider = WebDavProvider();
          await provider.loadComics(forceRefresh: false);
          final all = provider.comics ?? [];
          final readable = all
              .where((e) => !(e.isDirectory && e.isCategory))
              .toList();
          await provider.ensureCoverPaths(readable);
          final kw = keyword.trim().toLowerCase();
          final loaded = await provider.runBatches(
            readable.map(
              (e) =>
                  () async => (e, await _toComicAsync(e)),
            ),
          );
          final list = loaded
              .where((item) => kw.isEmpty || _matchSearch(item.$2, item.$1, kw))
              .map((item) => item.$2)
              .toList();
          list.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
          return Res(list, subData: 1);
        } catch (e) {
          return Res.error(e.toString());
        }
      }, null),
      settings,
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
      {
        'zh_CN': {
          'WebDAV': 'WebDAV',
          'WebDAV Comics': 'WebDAV 漫画',
          'Accounts': '账号',
          'Manage': '管理',
          'Author': '作者',
          '作者': '作者',
          '题材': '题材',
          '状态': '状态',
          '年份': '年份',
          '语言': '语言',
          '标签': '标签',
        },
        'zh_TW': {
          'WebDAV': 'WebDAV',
          'WebDAV Comics': 'WebDAV 漫畫',
          'Accounts': '帳號',
          'Manage': '管理',
          'Author': '作者',
          '作者': '作者',
          '题材': '題材',
          '状态': '狀態',
          '年份': '年份',
          '语言': '語言',
          '标签': '標籤',
        },
        'en_US': {
          'WebDAV': 'WebDAV',
          'WebDAV Comics': 'WebDAV Comics',
          'Accounts': 'Accounts',
          'Manage': 'Manage',
          'Author': 'Author',
        },
      },
      null, // handleClickTagEvent
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  static bool _matchSearch(Comic comic, WebDavComicEntry entry, String kw) {
    if (comic.title.toLowerCase().contains(kw)) return true;
    if ((comic.subtitle ?? '').toLowerCase().contains(kw)) return true;
    if (entry.name.toLowerCase().contains(kw)) return true;
    if (entry.path.toLowerCase().contains(kw)) return true;
    for (final t in comic.tags ?? const <String>[]) {
      if (t.toLowerCase().contains(kw)) return true;
    }
    return false;
  }

  /// Normalize cover paths for history/favorites/explore.
  /// Keeps stream://, webdav://, file://, http(s) intact; never double-prefix.
  static String _normalizeCover(String cover, [String? basePath]) {
    var c = cover.trim();
    if (c.isEmpty) return '';
    // Repair legacy double-prefixed stream covers.
    if (c.startsWith('webdav://stream://')) {
      c = c.substring(8); // -> stream://...
    }
    if (c.startsWith('webdav://') ||
        c.startsWith('stream://') ||
        c.startsWith('file://') ||
        c.startsWith('http://') ||
        c.startsWith('https://')) {
      return c;
    }
    if (basePath != null && basePath.isNotEmpty && !c.startsWith('/')) {
      final base = basePath.endsWith('/') ? basePath : '$basePath/';
      return 'webdav://$base$c';
    }
    return 'webdav://$c';
  }

  static String _coverOf(WebDavComicEntry e) {
    if (e.coverPath == null || e.coverPath!.isEmpty) {
      // Archive fallback: stream first image as cover.
      if (!e.isDirectory) return 'stream://${e.path}';
      return '';
    }
    return _normalizeCover(e.coverPath!, e.path);
  }

  static Future<Comic> _toComicAsync(WebDavComicEntry e) async {
    String title = e.name;
    String? author;
    final tags = <String>[];
    if (e.isDirectory) {
      final info = await WebDavProvider().loadComicInfo(e.path);
      if (info != null) {
        if (info.title != null && info.title!.trim().isNotEmpty) {
          title = info.title!.trim();
        }
        if (info.author != null && info.author!.trim().isNotEmpty) {
          author = info.author!.trim();
        }
        // Flatten dynamic tags from info.json for list display/search
        for (final entry in info.tags.entries) {
          for (final v in entry.value) {
            tags.add('${entry.key}:$v');
          }
        }
      }
    }
    final desc = e.isDirectory ? 'Folder'.tl : 'Archive'.tl;
    return Comic(
      title,
      _coverOf(e),
      e.path,
      author,
      tags,
      desc,
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

      final ComicInfo? info = isDirectory
          ? await provider.loadComicInfo(path)
          : null;

      String cover = '';
      if (info?.cover != null && info!.cover!.isNotEmpty) {
        cover = _normalizeCover(info.cover!, path);
      } else {
        final entry = WebDavComicEntry(
          name: name,
          path: path,
          isDirectory: isDirectory,
        );
        try {
          await WebDavComicClient().loadCover(entry);
          if (entry.coverPath != null) {
            cover = _normalizeCover(entry.coverPath!, path);
          }
        } catch (_) {}
      }
      // Archive without resolved cover: stream first image.
      if (cover.isEmpty && !isDirectory) {
        cover = 'stream://$path';
      }

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
        final images = await provider.getComicImages(path);
        maxPage = images.length;
      }

      // Tags come only from info.json — do not invent fixed namespaces.
      final tags = <String, List<String>>{};
      if (info != null && info.tags.isNotEmpty) {
        for (final e in info.tags.entries) {
          if (e.value.isNotEmpty) {
            tags[e.key] = List<String>.from(e.value);
          }
        }
      }

      // Author belongs in Information tags (like other sources), not subtitle.
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
          : name;

      final json = <String, dynamic>{
        'title': title,
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

  static Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
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
    final explorePages = List<String>.from(
      appdata.settings['explore_pages'] ?? [],
    );
    // Migrate old explore tab id
    if (explorePages.contains('WebDAV') &&
        !explorePages.contains(exploreTitle)) {
      final i = explorePages.indexOf('WebDAV');
      explorePages[i] = exploreTitle;
      appdata.settings['explore_pages'] = explorePages;
      appdata.saveData(false);
    } else if (!explorePages.contains(exploreTitle) &&
        !explorePages.contains('WebDAV')) {
      explorePages.add(exploreTitle);
      appdata.settings['explore_pages'] = explorePages;
      appdata.saveData(false);
    }
    manager.add(source);
  }
}
