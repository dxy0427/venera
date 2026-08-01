import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

import 'comic_info.dart';
import 'webdav_accounts.dart';
import 'webdav_models.dart';
import 'webdav_provider.dart';
import 'webdav_references.dart';
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

  static ComicSource? get _registered => ComicSource.find(key);

  static String _title(WebDavAccount account, Iterable<WebDavAccount> all) {
    final sameName = all.where((e) => e.name == account.name).toList();
    if (sameName.length == 1) return 'WebDAV · ${account.name}';
    final shortId = account.id.length <= 6
        ? account.id
        : account.id.substring(account.id.length - 6);
    return 'WebDAV · ${account.name} · $shortId';
  }

  static List<ExplorePageData> _buildExplorePages() {
    return explorePagesForAccounts(WebDavAccounts.list());
  }

  static List<ExplorePageData> explorePagesForAccounts(
    Iterable<WebDavAccount> sourceAccounts,
  ) {
    final accounts = sourceAccounts.where((e) => e.isValid).toList();
    final titles = <String>{};
    return accounts
        .map((account) {
          final baseTitle = _title(account, accounts);
          var title = baseTitle;
          var suffix = 2;
          while (!titles.add(title)) {
            title = '$baseTitle · $suffix';
            suffix++;
          }
          return ExplorePageData(
            title,
            ExplorePageType.multiPageComicList,
            (page) => _loadExplorePage(account.id, page),
            null,
            null,
            null,
          );
        })
        .toList(growable: false);
  }

  static Future<Res<List<Comic>>> _loadExplorePage(
    String accountId,
    int page,
  ) async {
    if (page > 1) return const Res([], subData: 1);
    try {
      final provider = WebDavProvider.forAccount(accountId);
      await provider.loadComics(forceRefresh: false);
      final comics = provider.comics ?? [];
      final readable = comics
          .where((e) => !(e.isDirectory && e.isCategory))
          .toList();
      await provider.ensureCoverPaths(readable);
      final list = await provider.runBatches(
        readable.map(
          (entry) =>
              () => _toComicAsync(provider, accountId, entry),
        ),
      );
      list.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      return Res(list, subData: 1);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

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
    final source = ComicSource(
      name,
      key,
      null, // account
      null, // categoryData
      null, // categoryComicsData
      null, // favoriteData
      _buildExplorePages(),
      SearchPageData(null, (keyword, page, options) async {
        if (page > 1) {
          return const Res([], subData: 1);
        }
        final accounts = WebDavAccounts.list().where((e) => e.isValid).toList();
        if (accounts.isEmpty) {
          return Res.error('WebDAV not configured'.tl);
        }
        try {
          final kw = keyword.trim().toLowerCase();
          final list = <Comic>[];
          for (final account in accounts) {
            final provider = WebDavProvider.forAccount(account.id);
            await provider.loadComics(forceRefresh: false);
            final readable = (provider.comics ?? [])
                .where((e) => !(e.isDirectory && e.isCategory))
                .toList();
            await provider.ensureCoverPaths(readable);
            final loaded = await provider.runBatches(
              readable.map(
                (e) =>
                    () async =>
                        (e, await _toComicAsync(provider, account.id, e)),
              ),
            );
            list.addAll(
              loaded
                  .where(
                    (item) => kw.isEmpty || _matchSearch(item.$2, item.$1, kw),
                  )
                  .map((item) => item.$2),
            );
          }
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
    source.data['accounts'] = WebDavAccounts.list().toString();
    return source;
  }

  static void syncRegisteredSource() {
    final source = _registered;
    if (source == null) return;
    final pages = _buildExplorePages();
    source.explorePages
      ..clear()
      ..addAll(pages);
    final validTitles = pages.map((e) => e.title).toSet();
    final current = List<String>.from(appdata.settings['explore_pages'] ?? []);
    appdata.settings['explore_pages'] = [
      ...current.where(
        (title) =>
            title != exploreTitle &&
            title != 'WebDAV' &&
            (!title.startsWith('WebDAV · ') || validTitles.contains(title)),
      ),
      ...pages.map((e) => e.title).where((title) => !current.contains(title)),
    ];
    appdata.saveData(false);
    ComicSourceManager().notifyStateChange();
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
  static String _normalizeCover(
    String cover,
    String accountId, [
    String? basePath,
  ]) {
    var c = cover.trim();
    if (c.isEmpty) return '';
    if (WebDavResourceRef.isReference(c)) return c;
    if (c.startsWith('stream://')) {
      return WebDavResourceRef.stream(accountId, c.substring(9)).encode();
    }
    if (c.startsWith('webdav://')) {
      c = c.substring(9);
    }
    if (c.startsWith('webdav://') ||
        c.startsWith('stream://') ||
        c.startsWith('file://') ||
        c.startsWith('http://') ||
        c.startsWith('https://')) {
      if (c.startsWith('webdav://') || c.startsWith('stream://')) {
        return c;
      }
      return c;
    }
    if (basePath != null && basePath.isNotEmpty && !c.startsWith('/')) {
      final base = basePath.endsWith('/') ? basePath : '$basePath/';
      return WebDavResourceRef.image(accountId, '$base$c').encode();
    }
    return WebDavResourceRef.image(accountId, c).encode();
  }

  static String _coverOf(WebDavComicEntry e, String accountId) {
    if (e.coverPath == null || e.coverPath!.isEmpty) {
      // Archive fallback: stream first image as cover.
      if (!e.isDirectory) {
        return WebDavResourceRef.stream(accountId, e.path).encode();
      }
      return '';
    }
    if (e.coverPath!.startsWith('stream://')) {
      return WebDavResourceRef.stream(
        accountId,
        e.coverPath!.substring(9),
      ).encode();
    }
    return _normalizeCover(e.coverPath!, accountId, e.path);
  }

  static Future<Comic> _toComicAsync(
    WebDavProvider provider,
    String accountId,
    WebDavComicEntry e,
  ) async {
    String title = e.name;
    String? author;
    final tags = <String>[];
    if (e.isDirectory) {
      final info = await provider.loadComicInfo(
        WebDavResourceRef.comic(accountId, e.path).encode(),
      );
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
      _coverOf(e, accountId),
      WebDavResourceRef.comic(accountId, e.path).encode(),
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
      final ref = WebDavResourceRef.parse(id);
      final provider = WebDavProvider.forAccount(ref.accountId);
      if (!provider.isConfigured) {
        return Res.error('WebDAV not configured'.tl);
      }

      final path = ref.remotePath;
      final name = path.split('/').where((s) => s.isNotEmpty).last;
      final isDirectory = path.endsWith('/');

      final ComicInfo? info = isDirectory
          ? await provider.loadComicInfo(id)
          : null;

      String cover = '';
      if (info?.cover != null && info!.cover!.isNotEmpty) {
        cover = _normalizeCover(info.cover!, ref.accountId, path);
      } else {
        final entry = WebDavComicEntry(
          name: name,
          path: path,
          isDirectory: isDirectory,
        );
        try {
          await provider.loadCover(entry);
          if (entry.coverPath != null) {
            cover = _coverOf(entry, ref.accountId);
          }
        } catch (_) {}
      }
      // Archive without resolved cover: stream first image.
      if (cover.isEmpty && !isDirectory) {
        cover = WebDavResourceRef.stream(ref.accountId, path).encode();
      }

      ComicChapters? chapters;
      int? maxPage;
      if (isDirectory) {
        final chapterList = await provider.getChapters(path);
        if (chapterList.isNotEmpty) {
          final map = <String, String>{};
          for (final c in chapterList) {
            map[WebDavResourceRef.chapter(ref.accountId, c.path).encode()] =
                c.name;
          }
          chapters = ComicChapters(map);
        } else {
          final images = await provider.getComicImages(id);
          maxPage = images.length;
        }
      } else {
        final images = await provider.getComicImages(id);
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
        'comicId': id,
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
      final comicRef = WebDavResourceRef.parse(id);
      final provider = WebDavProvider.forAccount(comicRef.accountId);
      List<String> images;
      if (ep != null && ep.isNotEmpty && ep != '0') {
        final chapterRef = WebDavResourceRef.parse(ep);
        if (chapterRef.accountId != comicRef.accountId) {
          throw WebDavAccountMismatchException(
            comicRef.accountId,
            chapterRef.accountId,
          );
        }
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
    if (manager.find(key) != null) {
      syncRegisteredSource();
      return;
    }
    final source = create();
    final explorePages = List<String>.from(
      appdata.settings['explore_pages'] ?? [],
    );
    final titles = source.explorePages.map((e) => e.title).toSet();
    appdata.settings['explore_pages'] = [
      ...explorePages.where((title) => titles.contains(title)),
      ...titles.where((title) => !explorePages.contains(title)),
    ];
    appdata.saveData(false);
    manager.add(source);
  }
}
