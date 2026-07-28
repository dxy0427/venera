import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/io.dart';

import 'webdav_accounts.dart';
import 'webdav_models.dart';
import 'streaming_zip.dart';

/// Supported image extensions for comic detection.
const _imageExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tiff', '.tif', '.avif',
};

/// Supported archive extensions for comic detection.
const _archiveExtensions = {'.cbz', '.zip', '.cb7', '.7z'};

/// WebDAV client wrapper for comic browsing.
class WebDavComicClient {
  webdav.Client? _client;
  String? _lastUrl;
  String? _lastUser;
  String? _lastPass;

  /// Get or create a WebDAV client from settings.
  webdav.Client getClient() {
    final config = getConfig();
    if (config == null) {
      throw Exception('WebDAV not configured');
    }
    final url = config[0];
    final user = config[1];
    final pass = config[2];

    // Reuse client if config hasn't changed
    if (_client != null &&
        _lastUrl == url &&
        _lastUser == user &&
        _lastPass == pass) {
      return _client!;
    }

    _client = webdav.newClient(
      url,
      user: user,
      password: pass,
      adapter: RHttpAdapter(
        enableProxy: appdata.settings['webdavProxyEnabled'] != false,
      ),
    );
    _lastUrl = url;
    _lastUser = user;
    _lastPass = pass;
    return _client!;
  }

  List<String>? getConfig() {
    final active = WebDavAccounts.active();
    if (active != null && active.isValid) {
      return active.configTriple;
    }
    final config = appdata.settings['webdavComicSource'];
    if (config is List && config.whereType<String>().length == 3) {
      final values = config.whereType<String>().toList();
      if (values[0].trim().isNotEmpty) {
        return values;
      }
    }
    // Fall back to the general WebDAV config
    final generalConfig = appdata.settings['webdav'];
    if (generalConfig is List &&
        generalConfig.whereType<String>().length == 3) {
      final values = generalConfig.whereType<String>().toList();
      if (values[0].trim().isNotEmpty) {
        return values;
      }
    }
    return null;
  }

  bool get isConfigured => getConfig() != null;

  String get remotePath {
    final active = WebDavAccounts.active();
    if (active != null) {
      return active.normalizedPath;
    }
    final path = appdata.settings['webdavComicPath'];
    if (path is String && path.trim().isNotEmpty) {
      return _normalizePath(path);
    }
    return '/';
  }

  static String _normalizePath(String path) {
    var result = path.trim().replaceAll('\\', '/');
    if (result.isEmpty) result = '/';
    if (!result.startsWith('/')) result = '/$result';
    if (!result.endsWith('/')) result = '$result/';
    return result;
  }

  /// Save WebDAV comic source configuration for the active account.
  static Future<void> saveConfig({
    required String url,
    required String user,
    required String pass,
    required String path,
    String? name,
  }) async {
    final active = WebDavAccounts.active();
    if (active != null) {
      active.url = url.trim();
      active.user = user.trim();
      active.pass = pass;
      active.path = path;
      if (name != null && name.trim().isNotEmpty) {
        active.name = name.trim();
      }
      await WebDavAccounts.update(active);
      return;
    }
    await WebDavAccounts.add(
      name: name?.trim().isNotEmpty == true ? name!.trim() : 'WebDAV',
      url: url,
      user: user,
      pass: pass,
      path: path,
    );
  }

  /// Test the connection.
  Future<void> testConnection({
    String? url,
    String? user,
    String? pass,
    String? path,
  }) async {
    if (url != null && url.trim().isNotEmpty) {
      final client = webdav.newClient(
        url.trim(),
        user: (user ?? '').trim(),
        password: pass ?? '',
        adapter: RHttpAdapter(
          enableProxy: appdata.settings['webdavProxyEnabled'] != false,
        ),
      );
      await client.readDir(_normalizePath(path ?? '/'));
      return;
    }
    final client = getClient();
    await client.readDir(remotePath);
  }

  /// List comic entries in the configured remote path.
  Future<List<WebDavComicEntry>> listComics() async {
    final client = getClient();
    final entries = <WebDavComicEntry>[];

    try {
      final items = await client.readDir(remotePath);

      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;

        final isDir = item.isDir == true;
        final ext = _getExtension(name).toLowerCase();

        if (isDir) {
          final dirPath = '$remotePath$name/';
          final isComic = await _isComicDirectory(dirPath);
          entries.add(WebDavComicEntry(
            name: _cleanName(name),
            path: dirPath,
            isDirectory: true,
            size: item.size ?? 0,
            modified: item.mTime,
            isCategory: !isComic,
          ));
        } else if (_archiveExtensions.contains(ext)) {
          // Archive file - cbz/zip comic
          entries.add(WebDavComicEntry(
            name: _cleanName(name),
            path: '$remotePath$name',
            isDirectory: false,
            size: item.size ?? 0,
            modified: item.mTime,
          ));
        }
      }
    } catch (e, s) {
      Log.error("WebDavClient", "Failed to list comics: $e\n$s");
      rethrow;
    }

    // Sort by name
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  /// List image files inside a comic directory.
  /// Excludes common cover files.
  Future<List<WebDavImageEntry>> listImages(String dirPath) async {
    final client = getClient();
    final images = <WebDavImageEntry>[];
    final coverNames = {
      'cover.jpg', 'cover.jpeg', 'cover.png',
      'folder.jpg', 'folder.jpeg', 'folder.png',
      'thumb.jpg', 'thumb.jpeg', 'thumb.png',
      '封面.jpg', '封面.jpeg', '封面.png',
    };

    try {
      final items = await client.readDir(dirPath);

      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;
        if (coverNames.contains(name.toLowerCase())) continue;

        final ext = _getExtension(name).toLowerCase();
        if (_imageExtensions.contains(ext)) {
          images.add(WebDavImageEntry(
            name: name,
            path: '$dirPath$name',
            size: item.size ?? 0,
          ));
        }
      }
    } catch (e, s) {
      Log.error("WebDavClient", "Failed to list images: $e\n$s");
      rethrow;
    }

    // Sort naturally by name
    images.sort((a, b) => _naturalCompare(a.name, b.name));
    return images;
  }

  /// List subdirectories (chapters) inside a comic directory.
  Future<List<WebDavChapter>> listChapters(String dirPath) async {
    final client = getClient();
    final chapters = <WebDavChapter>[];

    try {
      final items = await client.readDir(dirPath);

      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;

        if (item.isDir == true) {
          // Count images in subdirectory
          int imageCount = 0;
          try {
            final subItems = await client.readDir('$dirPath$name/');
            for (final sub in subItems) {
              final subName = sub.name ?? '';
              final ext = _getExtension(subName).toLowerCase();
              if (_imageExtensions.contains(ext)) {
                imageCount++;
              }
            }
          } catch (_) {
            // Ignore errors counting images
          }

          chapters.add(WebDavChapter(
            name: name,
            path: '$dirPath$name/',
            imageCount: imageCount,
          ));
        }
      }
    } catch (e, s) {
      Log.error("WebDavClient", "Failed to list chapters: $e\n$s");
      rethrow;
    }

    chapters.sort((a, b) => _naturalCompare(a.name, b.name));
    return chapters;
  }

  /// Resolve cover path only (no image download). Used by explore/list.
  Future<String?> resolveCoverPath(WebDavComicEntry comic) async {
    if (comic.coverPath != null && comic.coverPath!.isNotEmpty) {
      return comic.coverPath;
    }
    if (comic.isDirectory) {
      try {
        final coverNames = {
          'cover.jpg',
          'cover.jpeg',
          'cover.png',
          'folder.jpg',
          'folder.jpeg',
          'folder.png',
          'thumb.jpg',
          'thumb.jpeg',
          'thumb.png',
          'cover.webp',
          'folder.webp',
          '封面.jpg',
          '封面.jpeg',
          '封面.png',
        };
        final client = getClient();
        final items = await client.readDir(comic.path);
        String? firstImage;
        String? firstArchive;
        for (final item in items) {
          final name = item.name ?? '';
          if (name.isEmpty || name == '.') continue;
          if (item.isDir == true) continue;
          final lower = name.toLowerCase();
          final ext = _getExtension(name).toLowerCase();
          if (coverNames.contains(lower)) {
            comic.coverPath = '${comic.path}$name';
            return comic.coverPath;
          }
          if (firstImage == null && _imageExtensions.contains(ext)) {
            firstImage = '${comic.path}$name';
          }
          if (firstArchive == null && _archiveExtensions.contains(ext)) {
            firstArchive = '${comic.path}$name';
          }
        }
        if (firstImage != null) {
          comic.coverPath = firstImage;
          return comic.coverPath;
        }
        if (firstArchive != null) {
          // Cover will be loaded via stream from the archive entry later.
          comic.coverPath = 'stream://$firstArchive';
          return comic.coverPath;
        }
      } catch (_) {}
      return null;
    }

    // Archive comic (cbz/zip): cover is streamed from first image entry.
    comic.coverPath = 'stream://${comic.path}';
    return comic.coverPath;
  }

  /// Load a cover image for a comic entry.
  Future<Uint8List?> loadCover(WebDavComicEntry comic) async {
    final path = await resolveCoverPath(comic);
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('stream://')) {
      // Handled by provider stream loader.
      return null;
    }
    try {
      return await readImage(
        path.startsWith('webdav://') ? path.substring(8) : path,
      );
    } catch (_) {
      return null;
    }
  }

  /// Read an image file from WebDAV as bytes.
  Future<Uint8List> readImage(String path) async {
    final client = getClient();
    try {
      // Download to temp file, then read
      final tempDir = Directory.systemTemp;
      final tempFile = File(
        '${tempDir.path}/webdav_temp_${DateTime.now().microsecondsSinceEpoch}',
      );
      await client.read2File(path, tempFile.path);
      final data = await tempFile.readAsBytes();
      await tempFile.deleteIgnoreError();
      return data;
    } catch (e, s) {
      // Missing optional files (info.json / cover) are normal — keep log quiet.
      final msg = e.toString();
      if (msg.contains('404') || msg.contains('Not found')) {
        Log.info("WebDavClient", "Not found: $path");
      } else {
        Log.error("WebDavClient", "Failed to read image $path: $e\n$s");
      }
      rethrow;
    }
  }

  /// Check if a comic directory has subdirectories (chapters).
  Future<bool> hasChapters(String dirPath) async {
    try {
      final client = getClient();
      final items = await client.readDir(dirPath);
      for (final item in items) {
        if (item.isDir == true && (item.name ?? '') != '.') {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Whether a directory looks like a comic (has images or archives).
  Future<bool> _isComicDirectory(String path) async {
    try {
      final client = getClient();
      final items = await client.readDir(path);
      int imageCount = 0;
      int archiveCount = 0;
      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;
        if (item.isDir == true) continue;
        final ext = _getExtension(name).toLowerCase();
        if (_imageExtensions.contains(ext)) imageCount++;
        if (_archiveExtensions.contains(ext)) archiveCount++;
      }
      return imageCount > 0 || archiveCount > 0;
    } catch (_) {
      return false;
    }
  }

  /// List CBZ/ZIP files in a directory (for chapter-based comics).
  /// Excludes common cover files.
  Future<List<WebDavImageEntry>> listCbzFiles(String dirPath) async {
    final client = getClient();
    final files = <WebDavImageEntry>[];
    final coverNames = {
      'cover.jpg', 'cover.jpeg', 'cover.png',
      'folder.jpg', 'folder.jpeg', 'folder.png',
      'thumb.jpg', 'thumb.jpeg', 'thumb.png',
      'cover.cbz', 'folder.cbz',
    };

    try {
      final items = await client.readDir(dirPath);
      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.') continue;
        if (coverNames.contains(name.toLowerCase())) continue;
        final ext = _getExtension(name).toLowerCase();
        if (_archiveExtensions.contains(ext)) {
          files.add(WebDavImageEntry(
            name: name,
            path: '$dirPath$name',
            size: item.size ?? 0,
          ));
        }
      }
    } catch (e, s) {
      Log.error("WebDavClient", "Failed to list cbz files: $e\n$s");
      rethrow;
    }

    files.sort((a, b) => _naturalCompare(a.name, b.name));
    return files;
  }

  /// Build a correctly encoded absolute URL.
  ///
  /// [Uri.pathSegments] must receive *decoded* segments; Uri encodes once
  /// when serializing. Do NOT pre-call [Uri.encodeComponent] or paths become
  /// double/triple-encoded (%25E5...) and 123pan returns 404.
  static String buildEncodedUrl(String baseUrl, String remotePath) {
    final base = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
    final raw = remotePath.startsWith('/') ? remotePath.substring(1) : remotePath;
    final extra = raw
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.decodeComponent)
        .toList();
    return base.replace(pathSegments: [...base.pathSegments, ...extra]).toString();
  }

  /// Download a file from WebDAV to a local path.
  /// [onProgress] receives bytes received and total bytes (-1 if unknown).
  Future<void> downloadFile(String remotePath, String localPath,
      {void Function(int received, int total)? onProgress}) async {
    try {
      // Use dio for progress tracking
      final dio = AppDio(BaseOptions(
        method: 'GET',
        responseType: ResponseType.stream,
      ));

      final config = getConfig();
      if (config == null) throw Exception('WebDAV not configured');

      final fullUrl = buildEncodedUrl(config[0], remotePath);

      final req = await dio.request<ResponseBody>(
        fullUrl,
        options: Options(
          headers: {
            'authorization': 'Basic ${base64Encode(utf8.encode('${config[1]}:${config[2]}'))}',
          },
        ),
      );

      final stream = req.data?.stream ?? (throw Exception('Empty response'));
      final totalBytes = req.data!.contentLength;
      final file = File(localPath);
      final sink = file.openWrite();
      int received = 0;

      await for (final chunk in stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, totalBytes);
      }

      await sink.close();
    } catch (e, s) {
      Log.error("WebDavClient", "Failed to download $remotePath: $e\n$s");
      rethrow;
    }
  }

  static String _getExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0) return '';
    return name.substring(dotIndex);
  }

  static String _cleanName(String name) {
    // Remove trailing slash for directories
    var cleaned = name;
    if (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    // Remove file extension for archive files
    final dotIndex = cleaned.lastIndexOf('.');
    if (dotIndex > 0) {
      final ext = cleaned.substring(dotIndex).toLowerCase();
      if (_archiveExtensions.contains(ext)) {
        cleaned = cleaned.substring(0, dotIndex);
      }
    }
    return cleaned;
  }

  /// Special chapter prefixes that should sort AFTER regular chapters.
  static const _chapterSuffixesAfter = [
    '后记', '后日谈', '番外', '特典', '附录',
    'afterword', 'extra', 'bonus', 'omake', 'special',
  ];

  /// Special chapter prefixes that should sort BEFORE regular chapters.
  static const _chapterSuffixesBefore = [
    '预告', '预览', 'preview', 'prologue', '序章', '序幕',
  ];

  /// Extract the leading number from a chapter name, or -1 if none.
  static int _extractChapterNumber(String name) {
    final match = RegExp(r'^(\d+)').firstMatch(name);
    if (match != null) return int.parse(match.group(1)!);
    // Also match Chinese numerals like 第0话, 第1话
    final match2 = RegExp(r'第(\d+)').firstMatch(name);
    if (match2 != null) return int.parse(match2.group(1)!);
    return -1;
  }

  /// 0 = before (预告), 1 = normal, 2 = after (后记)
  static int _chapterGroup(String name) {
    final lower = name.toLowerCase();
    for (final suffix in _chapterSuffixesBefore) {
      if (lower.startsWith(suffix)) return 0;
    }
    for (final suffix in _chapterSuffixesAfter) {
      if (lower.startsWith(suffix)) return 2;
    }
    return 1;
  }

  /// Get file extension (with dot).
  String getExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0) return '';
    return name.substring(dotIndex);
  }

  /// Whether the extension is an image type.
  bool isImage(String ext) => _imageExtensions.contains(ext);

  /// Whether the extension is an archive type.
  bool isArchive(String ext) => _archiveExtensions.contains(ext);

  /// Clean directory/file name for display.
  String cleanName(String name) => _cleanName(name);

  static int _naturalCompare(String a, String b) {
    // Extract base name (remove extension)
    final nameA = a.contains('.') ? a.substring(0, a.lastIndexOf('.')) : a;
    final nameB = b.contains('.') ? b.substring(0, b.lastIndexOf('.')) : b;

    final groupA = _chapterGroup(nameA);
    final groupB = _chapterGroup(nameB);
    final numA = _extractChapterNumber(nameA);
    final numB = _extractChapterNumber(nameB);

    // Different groups: before(0) < normal(1) < after(2)
    if (groupA != groupB) return groupA.compareTo(groupB);

    // Same group, both have numbers: sort by number
    if (numA >= 0 && numB >= 0) return numA.compareTo(numB);

    // One has number, one doesn't: number comes first
    if (numA >= 0 && numB < 0) return -1;
    if (numA < 0 && numB >= 0) return 1;

    // Neither has number: natural sort on full string
    final aParts = _splitNatural(a);
    final bParts = _splitNatural(b);
    final minLen =
        aParts.length < bParts.length ? aParts.length : bParts.length;
    for (int i = 0; i < minLen; i++) {
      final aIsNum = int.tryParse(aParts[i]) != null;
      final bIsNum = int.tryParse(bParts[i]) != null;
      if (aIsNum && bIsNum) {
        final cmp = int.parse(aParts[i]).compareTo(int.parse(bParts[i]));
        if (cmp != 0) return cmp;
      } else {
        final cmp = aParts[i].compareTo(bParts[i]);
        if (cmp != 0) return cmp;
      }
    }
    return aParts.length.compareTo(bParts.length);
  }

  static List<String> _splitNatural(String s) {
    final parts = <String>[];
    final buffer = StringBuffer();
    bool? wasDigit;
    for (int i = 0; i < s.length; i++) {
      final isDigit = s[i].codeUnitAt(0) >= 48 && s[i].codeUnitAt(0) <= 57;
      if (wasDigit != null && isDigit != wasDigit) {
        parts.add(buffer.toString());
        buffer.clear();
      }
      buffer.write(s[i]);
      wasDigit = isDigit;
    }
    if (buffer.isNotEmpty) parts.add(buffer.toString());
    return parts;
  }
}
