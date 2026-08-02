import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/natural_sort.dart';

import 'webdav_accounts.dart';
import 'webdav_client.dart';
import 'webdav_models.dart';
import 'webdav_references.dart';
import 'streaming_zip.dart';
import 'comic_info.dart';

/// Manages WebDAV comic state - connection, caching, and data.
class WebDavProvider with ChangeNotifier {
  static final Map<String, WebDavProvider> _instances = {};

  final String accountId;
  late WebDavComicClient _client;

  WebDavProvider._(this.accountId) {
    final account = WebDavAccounts.find(accountId);
    if (account == null) {
      throw WebDavAccountMissingException(accountId);
    }
    _client = WebDavComicClient(account);
  }

  factory WebDavProvider.forAccount(String accountId) {
    final account = WebDavAccounts.find(accountId);
    if (account == null) throw WebDavAccountMissingException(accountId);
    return _instances.putIfAbsent(accountId, () => WebDavProvider._(accountId));
  }

  static WebDavProvider? existing(String accountId) => _instances[accountId];

  static void release(String accountId) {
    _instances.remove(accountId)?.disposeProvider();
  }

  static void releaseMissingAccounts() {
    final ids = _instances.keys
        .where((id) => WebDavAccounts.find(id) == null)
        .toList();
    for (final id in ids) {
      release(id);
    }
  }

  bool _disposed = false;
  bool get isDisposed => _disposed;

  void disposeProvider() {
    _disposed = true;
    for (final info in _streamingReaders.values) {
      info.reader.dispose();
    }
    _streamingReaders.clear();
    dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  List<WebDavComicEntry>? _comics;
  bool _isLoading = false;
  String? _error;

  List<WebDavComicEntry>? get comics => _comics;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConfigured => _client.isConfigured;

  String get _accountScope => accountId;

  void _requireAccount() {
    if (WebDavAccounts.find(accountId) == null) {
      throw WebDavAccountMissingException(accountId);
    }
  }

  String _cacheKey(String prefix, String path) =>
      '${prefix}_${_accountScope}_$path';

  /// Currently downloading chapter paths (for progress display).
  final Set<String> _downloadingChapters = {};
  Set<String> get downloadingChapters => _downloadingChapters;

  /// Download progress for each chapter (0.0 ~ 1.0).
  final Map<String, double> _downloadProgress = {};
  double? getDownloadProgress(String path) => _downloadProgress[path];

  /// Load comics list from WebDAV server.
  Future<void> loadComics({bool forceRefresh = false}) async {
    _requireAccount();
    if (_isLoading) return;
    if (!isConfigured) {
      _error = 'WebDAV not configured';
      notifyListeners();
      return;
    }

    if (!forceRefresh && _comics != null && _directoryEntries == null) return;

    _isLoading = true;
    _error = null;
    _directoryEntries = null;
    if (forceRefresh) _client.clearDirectoryCache();
    notifyListeners();

    try {
      _comics = await _client.listComics();
      if (_comics != null) _rememberEntrySizes(_comics!);
      _loadCoversInBackground();
    } catch (e) {
      _error = e.toString();
      _comics = null;
      Log.error("WebDavProvider", "Failed to load comics: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> ensureCoverPaths(List<WebDavComicEntry> comics) async {
    const batchSize = 6;
    for (var i = 0; i < comics.length; i += batchSize) {
      final batch = comics.skip(i).take(batchSize);
      await Future.wait(
        batch.map((comic) async {
          if (comic.isDirectory && comic.isCategory) return;
          if (comic.coverPath != null && comic.coverPath!.isNotEmpty) return;
          try {
            await _client.resolveCoverPath(comic);
          } catch (e) {
            Log.error(
              "WebDavProvider",
              "Failed to resolve cover for ${comic.name}: $e",
            );
          }
        }),
      );
    }
  }

  Future<Uint8List?> loadCover(WebDavComicEntry comic) {
    return _client.loadCover(comic);
  }

  Future<List<T>> runBatches<T>(
    Iterable<Future<T> Function()> tasks, {
    int batchSize = 6,
  }) async {
    final list = tasks.toList();
    final result = <T>[];
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      result.addAll(await Future.wait(batch.map((task) => task())));
    }
    return result;
  }

  void _loadCoversInBackground() async {
    if (_comics == null) return;
    await ensureCoverPaths(_comics!);
    if (_comics != null) notifyListeners();
  }

  /// Get image paths for a comic.
  Future<List<String>> getComicImages(String comicId) async {
    _requireAccount();
    final ref = WebDavResourceRef.parse(comicId);
    _checkAccount(ref);
    if (ref.kind != WebDavResourceKind.comic) {
      throw const FormatException('Expected a WebDAV comic reference');
    }
    final path = ref.remotePath;
    if (path.endsWith('/')) {
      final hasChapters = await _client.hasChapters(path);
      if (hasChapters) return [];
      final images = await _client.listImages(path);
      return images
          .map((e) => WebDavResourceRef.image(accountId, e.path).encode())
          .toList();
    } else {
      // Stream CBZ via Range. Do not silently fall back to full download
      // for huge archives — that blocks reading until the whole file is saved.
      return await _streamCbz(path);
    }
  }

  /// Get chapters for a comic.
  Future<List<WebDavChapter>> getChapters(String dirPath) async {
    _requireAccount();
    final chapters = await _client.listChapters(dirPath);
    if (chapters.isNotEmpty) return chapters;
    final cbzFiles = await _client.listCbzFiles(dirPath);
    if (cbzFiles.isNotEmpty) {
      for (final f in cbzFiles) {
        _rememberArchiveSize(f.path, f.size);
      }
      return cbzFiles
          .map((f) => WebDavChapter(name: f.name, path: f.path, imageCount: 0))
          .toList();
    }
    return [];
  }

  /// Get images for a specific chapter.
  Future<List<String>> getChapterImages(String chapterPath) async {
    _requireAccount();
    final ref = WebDavResourceRef.parse(chapterPath);
    _checkAccount(ref);
    if (ref.kind != WebDavResourceKind.chapter) {
      throw const FormatException('Expected a WebDAV chapter reference');
    }
    chapterPath = ref.remotePath;
    final lowerPath = chapterPath.toLowerCase();
    if (lowerPath.endsWith('.cbz') || lowerPath.endsWith('.zip')) {
      return await _streamCbz(chapterPath);
    }
    final images = await _client.listImages(chapterPath);
    return images
        .map((e) => WebDavResourceRef.image(accountId, e.path).encode())
        .toList();
  }

  void _checkAccount(WebDavResourceRef ref) {
    if (ref.accountId != accountId) {
      throw WebDavAccountMismatchException(accountId, ref.accountId);
    }
  }

  /// Get the cache directory for a CBZ file (offline extract fallback only).
  Directory getCbzCacheDir(String remotePath) {
    final pathHash = remotePath.hashCode.toRadixString(16);
    return Directory(
      FilePath.join(App.cachePath, 'webdav_cbz', _accountScope, pathHash),
    );
  }

  /// Check if a CBZ is already fully extracted offline.
  bool isCbzCached(String remotePath) {
    final dir = getCbzCacheDir(remotePath);
    if (!dir.existsSync()) return false;
    return _listLocalImages(dir).isNotEmpty;
  }

  Future<_StreamInfo> _ensureStreamReader(String remotePath) async {
    final existing = _streamingReaders[remotePath];
    if (existing != null) return existing;

    final config = _client.getConfig();
    if (config == null) throw Exception('WebDAV not configured');

    final base = config[0].replaceAll(RegExp(r'/+$'), '');
    final fullPath = remotePath.startsWith('/') ? remotePath : '/$remotePath';
    final webdavUrl = WebDavComicClient.buildEncodedUrl(base, fullPath);
    final knownSize = _archiveSizes[remotePath];
    final reader = StreamingZipReader(
      webdavUrl: webdavUrl,
      user: config[1],
      pass: config[2],
      knownFileSize: knownSize,
    );

    try {
      final entries = await reader.listEntries();
      final imageEntries = entries.where((e) {
        if (e.isDirectory) return false;
        final ext = _getExtension(e.fileName).toLowerCase();
        return {
          '.jpg',
          '.jpeg',
          '.png',
          '.gif',
          '.webp',
          '.bmp',
          '.tiff',
          '.tif',
        }.contains(ext);
      }).toList();
      imageEntries.sort((a, b) => naturalCompare(a.fileName, b.fileName));
      if (imageEntries.isEmpty) {
        reader.dispose();
        throw Exception('No images in CBZ');
      }
      final info = _StreamInfo(reader: reader, entries: imageEntries);
      _streamingReaders[remotePath] = info;
      return info;
    } catch (e) {
      reader.dispose();
      rethrow;
    }
  }

  /// Stream a CBZ file: list entries and return image paths with stream://.
  /// Does NOT download the whole archive first.
  Future<List<String>> _streamCbz(String remotePath) async {
    final info = await _ensureStreamReader(remotePath);
    return info.entries
        .map(
          (e) => WebDavResourceRef.stream(
            accountId,
            remotePath,
            e.fileName,
          ).encode(),
        )
        .toList();
  }

  /// Cache for streaming ZIP readers (in-memory; rebuilt on demand).
  final Map<String, _StreamInfo> _streamingReaders = {};

  /// Avoid refetching info.json while the current account is being browsed.
  final Map<String, Future<ComicInfo?>> _comicInfoRequests = {};

  /// PROPFIND sizes for archive paths (used by StreamingZipReader).
  final Map<String, int> _archiveSizes = {};

  void _rememberArchiveSize(String path, int size) {
    if (size > 0) _archiveSizes[path] = size;
  }

  void _rememberEntrySizes(Iterable<WebDavComicEntry> entries) {
    for (final e in entries) {
      if (!e.isDirectory) _rememberArchiveSize(e.path, e.size);
    }
  }

  /// Load a single image from a streaming CBZ entry.
  ///
  /// [streamPath] formats:
  /// - `stream://remotePath::entryFileName`
  /// - `stream://remotePath` (first image, used as cover)
  Future<Uint8List> loadStreamImage(String streamPath) async {
    _requireAccount();
    final ref = WebDavResourceRef.parse(streamPath);
    if (ref.accountId != accountId || !ref.isStream) {
      throw WebDavAccountMismatchException(accountId, ref.accountId);
    }
    final remotePath = ref.remotePath;
    var entryName = ref.entryName;

    final info = await _ensureStreamReader(remotePath);
    entryName ??= info.entries.first.fileName;

    final cacheKey = _cacheKey('webdav_stream', '${ref.encode()}/$entryName');
    final cached = await CacheManager().findCache(cacheKey);
    if (cached != null) return cached.readAsBytes();

    final data = await info.reader.readEntry(entryName);
    await CacheManager().writeCache(cacheKey, data, 7 * 24 * 60 * 60 * 1000);
    return data;
  }

  /// Download a CBZ file, extract it, return local image paths.
  Future<List<String>> _downloadAndExtractCbz(String remotePath) async {
    final cacheDir = getCbzCacheDir(remotePath);

    // Already cached?
    if (cacheDir.existsSync()) {
      final images = _listLocalImages(cacheDir);
      if (images.isNotEmpty) return images;
      await cacheDir.delete(recursive: true);
    }

    // Download with progress tracking
    _downloadingChapters.add(remotePath);
    _downloadProgress[remotePath] = 0.0;
    notifyListeners();

    await cacheDir.create(recursive: true);
    final cbzFile = File(FilePath.join(cacheDir.path, 'archive.cbz'));

    try {
      // Download with progress
      await _client.downloadFile(
        remotePath,
        cbzFile.path,
        onProgress: (received, total) {
          if (total > 0) {
            _downloadProgress[remotePath] = received / total;
            notifyListeners();
          }
        },
      );

      _downloadProgress[remotePath] = 1.0;
      notifyListeners();

      // Extract
      await CBZ.extractArchive(cbzFile, cacheDir);
      await cbzFile.deleteIgnoreError();

      final images = _listLocalImages(cacheDir);
      if (images.isEmpty) throw Exception('No images found in archive');
      return images;
    } catch (e) {
      await cacheDir.deleteIgnoreError(recursive: true);
      rethrow;
    } finally {
      _downloadingChapters.remove(remotePath);
      _downloadProgress.remove(remotePath);
      notifyListeners();
    }
  }

  /// Pre-download a chapter in the background.
  void preDownloadChapter(String chapterPath) {
    final lowerPath = chapterPath.toLowerCase();
    if (lowerPath.endsWith('.cbz') || lowerPath.endsWith('.zip')) {
      if (isCbzCached(chapterPath)) return;
      if (_downloadingChapters.contains(chapterPath)) return;
      _downloadAndExtractCbz(chapterPath).catchError((e) {
        Log.error("WebDavProvider", "Pre-download failed: $e");
        return <String>[];
      });
    }
  }

  List<String> _listLocalImages(Directory dir) {
    final imageExtensions = {
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.tiff',
      '.tif',
    };
    final files = <File>[];
    for (final entity in dir.listSync()) {
      if (entity is File) {
        final ext = _getExtension(entity.name).toLowerCase();
        if (imageExtensions.contains(ext)) {
          files.add(entity);
        }
      }
    }
    files.sort((a, b) => naturalCompare(a.name, b.name));
    return files.map((e) => 'file://${e.path}').toList();
  }

  static String _getExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0) return '';
    return name.substring(dotIndex);
  }

  /// Load an image from WebDAV or streaming CBZ with caching.
  Future<Uint8List> loadImage(String path) async {
    _requireAccount();
    // Local extracted images (offline fallback)
    if (path.startsWith('file://')) {
      return File(path.substring(7)).readAsBytes();
    }
    // Streaming CBZ entry / cover (first image when no ::entry)
    if (WebDavResourceRef.isReference(path)) {
      final ref = WebDavResourceRef.parse(path);
      if (ref.accountId != accountId) {
        throw WebDavAccountMismatchException(accountId, ref.accountId);
      }
      if (ref.isStream) return loadStreamImage(path);
      if (ref.kind != WebDavResourceKind.image) {
        throw Exception('Invalid WebDAV image reference');
      }
      path = ref.remotePath;
    } else {
      throw Exception('Unbound WebDAV image reference');
    }
    if (path.startsWith('stream://')) {
      return loadStreamImage(path);
    }

    final realPath = path.startsWith('webdav://') ? path.substring(8) : path;
    final cacheKey = _cacheKey('webdav_img', realPath);
    final cached = await CacheManager().findCache(cacheKey);
    if (cached != null) return cached.readAsBytes();
    final data = await _client.readImage(realPath);
    await CacheManager().writeCache(cacheKey, data, 7 * 24 * 60 * 60 * 1000);
    return data;
  }

  /// List of entries for current browsing directory.
  List<WebDavComicEntry>? _directoryEntries;
  List<WebDavComicEntry>? get directoryEntries => _directoryEntries;

  /// Load contents of a specific directory for browsing.
  Future<void> loadDirectory(String path) async {
    _requireAccount();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final items = await _client.readDirectory(path);
      final entries = <WebDavComicEntry>[];
      final directoryItems = items.where((item) => item.isDir == true).toList();
      final comicDirectories = <String, bool>{};
      const batchSize = 6;
      for (var i = 0; i < directoryItems.length; i += batchSize) {
        final batch = directoryItems.skip(i).take(batchSize);
        await Future.wait(
          batch.map((item) async {
            final name = item.name ?? '';
            if (name.isNotEmpty && name != '.') {
              comicDirectories[name] = await _client.isComicDirectory(
                '$path$name/',
              );
            }
          }),
        );
      }

      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;

        final isDir = item.isDir == true;
        final ext = _client.getExtension(name).toLowerCase();

        if (isDir) {
          // Check if this directory is a comic or a category
          final isComic = comicDirectories[name] ?? false;
          entries.add(
            WebDavComicEntry(
              name: name,
              path: '$path$name/',
              isDirectory: true,
              size: item.size ?? 0,
              modified: item.mTime,
              isCategory: !isComic,
            ),
          );
        } else if (_client.isArchive(ext)) {
          entries.add(
            WebDavComicEntry(
              name: _client.cleanName(name),
              path: '$path$name',
              isDirectory: false,
              size: item.size ?? 0,
              modified: item.mTime,
            ),
          );
        }
      }

      _directoryEntries = entries;
      _rememberEntrySizes(entries);
    } catch (e) {
      _error = e.toString();
      _directoryEntries = null;
      Log.error("WebDavProvider", "Failed to load directory: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final current = _refreshTask;
    if (current != null) return current;
    final task = _refreshInternal();
    _refreshTask = task;
    try {
      await task;
    } finally {
      if (identical(_refreshTask, task)) _refreshTask = null;
    }
  }

  Future<void>? _refreshTask;

  Future<void> _refreshInternal() async {
    _comics = null;
    _directoryEntries = null;
    _error = null;
    for (final info in _streamingReaders.values) {
      info.reader.dispose();
    }
    _streamingReaders.clear();
    _archiveSizes.clear();
    _comicInfoRequests.clear();
    final account = WebDavAccounts.find(accountId);
    if (account == null) throw WebDavAccountMissingException(accountId);
    _client = WebDavComicClient(account);
    await loadComics(forceRefresh: true);
  }

  /// Load info.json from a comic directory (with caching).
  Future<ComicInfo?> loadComicInfo(String comicPath) async {
    _requireAccount();
    final ref = WebDavResourceRef.parse(comicPath);
    _checkAccount(ref);
    if (ref.kind != WebDavResourceKind.comic) {
      throw const FormatException('Expected a WebDAV comic reference');
    }
    comicPath = ref.remotePath;
    final cacheKey = _cacheKey('webdav_info_v2', comicPath);
    final pending = _comicInfoRequests[cacheKey];
    if (pending != null) return pending;
    final request = _loadComicInfo(cacheKey, comicPath);
    _comicInfoRequests[cacheKey] = request;
    return request;
  }

  Future<ComicInfo?> _loadComicInfo(String cacheKey, String comicPath) async {
    // Check cache first
    final cached = await CacheManager().findCache(cacheKey);
    if (cached != null) {
      try {
        final bytes = await cached.readAsBytes();
        final content = utf8
            .decode(bytes, allowMalformed: true)
            .replaceFirst('\uFEFF', '');
        final json = Map<String, dynamic>.from(
          const JsonDecoder().convert(content) as Map,
        );
        return ComicInfo.fromJson(json);
      } catch (_) {
        // Cache corrupted, re-fetch
      }
    }

    try {
      final infoPath = '${comicPath}info.json';
      final data = await _client.readImage(infoPath);

      await CacheManager().writeCache(cacheKey, data, 7 * 24 * 60 * 60 * 1000);

      final content = utf8
          .decode(data, allowMalformed: true)
          .replaceFirst('\uFEFF', '');
      final json = Map<String, dynamic>.from(
        const JsonDecoder().convert(content) as Map,
      );
      return ComicInfo.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> testConnection() async {
    _requireAccount();
    await _client.testConnection();
  }
}

class _StreamInfo {
  final StreamingZipReader reader;
  final List<ZipEntryInfo> entries;

  _StreamInfo({required this.reader, required this.entries});
}
