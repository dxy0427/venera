import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
import 'streaming_zip.dart';
import 'comic_info.dart';

/// Manages WebDAV comic state - connection, caching, and data.
class WebDavProvider with ChangeNotifier {
  static WebDavProvider? _instance;

  WebDavProvider._();

  factory WebDavProvider() => _instance ??= WebDavProvider._();

  WebDavComicClient _client = WebDavComicClient();
  List<WebDavComicEntry>? _comics;
  bool _isLoading = false;
  String? _error;

  List<WebDavComicEntry>? get comics => _comics;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConfigured => _client.isConfigured;

  String get _accountScope {
    final id = WebDavAccounts.activeId();
    return (id == null || id.isEmpty) ? 'default' : id;
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
    notifyListeners();

    try {
      _comics = await _client.listComics();
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
    for (final comic in comics) {
      if (comic.isDirectory && comic.isCategory) continue;
      if (comic.coverPath != null && comic.coverPath!.isNotEmpty) continue;
      try {
        await _client.resolveCoverPath(comic);
      } catch (e) {
        Log.error(
          "WebDavProvider",
          "Failed to resolve cover for ${comic.name}: $e",
        );
      }
    }
  }

  void _loadCoversInBackground() async {
    if (_comics == null) return;
    await ensureCoverPaths(_comics!);
    if (_comics != null) notifyListeners();
  }

  /// Get image paths for a comic.
  Future<List<String>> getComicImages(String comicId) async {
    final path = comicId;
    if (path.endsWith('/')) {
      final hasChapters = await _client.hasChapters(path);
      if (hasChapters) return [];
      final images = await _client.listImages(path);
      return images.map((e) => 'webdav://${e.path}').toList();
    } else {
      // Stream CBZ via Range. Do not silently fall back to full download
      // for huge archives — that blocks reading until the whole file is saved.
      return await _streamCbz(path);
    }
  }

  /// Get chapters for a comic.
  Future<List<WebDavChapter>> getChapters(String dirPath) async {
    final chapters = await _client.listChapters(dirPath);
    if (chapters.isNotEmpty) return chapters;
    final cbzFiles = await _client.listCbzFiles(dirPath);
    if (cbzFiles.isNotEmpty) {
      return cbzFiles
          .map((f) => WebDavChapter(name: f.name, path: f.path, imageCount: 0))
          .toList();
    }
    return [];
  }

  /// Get images for a specific chapter.
  Future<List<String>> getChapterImages(String chapterPath) async {
    if (chapterPath.endsWith('.cbz') ||
        chapterPath.endsWith('.zip') ||
        chapterPath.endsWith('.cbr')) {
      return await _streamCbz(chapterPath);
    }
    final images = await _client.listImages(chapterPath);
    return images.map((e) => 'webdav://${e.path}').toList();
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
    final reader = StreamingZipReader(
      webdavUrl: webdavUrl,
      user: config[1],
      pass: config[2],
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
        .map((e) => 'stream://$remotePath::${e.fileName}')
        .toList();
  }

  /// Cache for streaming ZIP readers (in-memory; rebuilt on demand).
  final Map<String, _StreamInfo> _streamingReaders = {};

  /// Load a single image from a streaming CBZ entry.
  ///
  /// [streamPath] formats:
  /// - `stream://remotePath::entryFileName`
  /// - `stream://remotePath` (first image, used as cover)
  Future<Uint8List> loadStreamImage(String streamPath) async {
    final withoutProtocol = streamPath.substring(9); // remove 'stream://'
    String remotePath;
    String? entryName;
    final sep = withoutProtocol.indexOf('::');
    if (sep < 0) {
      remotePath = withoutProtocol;
      entryName = null;
    } else {
      remotePath = withoutProtocol.substring(0, sep);
      entryName = withoutProtocol.substring(sep + 2);
    }

    final info = await _ensureStreamReader(remotePath);
    entryName ??= info.entries.first.fileName;

    final cacheKey = _cacheKey('webdav_stream', '$remotePath/$entryName');
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
    if (chapterPath.endsWith('.cbz') || chapterPath.endsWith('.zip')) {
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
    // Repair legacy double-prefixed stream covers.
    if (path.startsWith('webdav://stream://')) {
      path = path.substring(8);
    }
    // Local extracted images (offline fallback)
    if (path.startsWith('file://')) {
      return File(path.substring(7)).readAsBytes();
    }
    // Streaming CBZ entry / cover (first image when no ::entry)
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
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final client = _client.getClient();
      final items = await client.readDir(path);
      final entries = <WebDavComicEntry>[];

      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;

        final isDir = item.isDir == true;
        final ext = _client.getExtension(name).toLowerCase();

        if (isDir) {
          // Check if this directory is a comic or a category
          final isComic = await _isComicDirectory('$path$name/');
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
    } catch (e) {
      _error = e.toString();
      _directoryEntries = null;
      Log.error("WebDavProvider", "Failed to load directory: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Check if a directory contains comics (images or archives) directly.
  Future<bool> _isComicDirectory(String path) async {
    try {
      final client = _client.getClient();
      final items = await client.readDir(path);
      int imageCount = 0;
      int archiveCount = 0;
      int subDirCount = 0;

      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;
        if (item.isDir == true) {
          subDirCount++;
        } else {
          final ext = _client.getExtension(name).toLowerCase();
          if (_client.isImage(ext)) imageCount++;
          if (_client.isArchive(ext)) archiveCount++;
        }
      }

      // It's a comic if it has images or archives
      return imageCount > 0 || archiveCount > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    _comics = null;
    _directoryEntries = null;
    _error = null;
    for (final info in _streamingReaders.values) {
      info.reader.dispose();
    }
    _streamingReaders.clear();
    _client = WebDavComicClient();
    await loadComics(forceRefresh: true);
  }

  /// Load info.json from a comic directory (with caching).
  Future<ComicInfo?> loadComicInfo(String comicPath) async {
    final cacheKey = _cacheKey('webdav_info_v2', comicPath);

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
    await _client.testConnection();
  }
}

class _StreamInfo {
  final StreamingZipReader reader;
  final List<ZipEntryInfo> entries;

  _StreamInfo({required this.reader, required this.entries});
}
