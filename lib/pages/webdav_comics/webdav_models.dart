/// A WebDAV comic entry - represents a directory containing images or an archive file.
class WebDavComicEntry {
  /// Display name (directory or file name without extension)
  final String name;

  /// Full remote path on the WebDAV server
  final String path;

  /// Whether this is a directory (folder of images) or a file (cbz/zip archive)
  final bool isDirectory;

  /// File size in bytes (0 for directories)
  final int size;

  /// Last modified time
  final DateTime? modified;

  /// Cover image path (first image found, or null)
  String? coverPath;

  /// Number of images inside (computed on demand)
  int? imageCount;

  /// Whether this is a category folder (contains only subdirectories)
  final bool isCategory;

  WebDavComicEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modified,
    this.coverPath,
    this.imageCount,
    this.isCategory = false,
  });
}

/// A chapter/episode inside a WebDAV comic (for directory-based comics with subdirectories).
class WebDavChapter {
  /// Chapter display name
  final String name;

  /// Chapter directory path
  final String path;

  /// Number of images in this chapter
  final int imageCount;

  const WebDavChapter({
    required this.name,
    required this.path,
    required this.imageCount,
  });
}

/// Represents a page image in a WebDAV comic.
class WebDavImageEntry {
  final String name;
  final String path;
  final int size;

  const WebDavImageEntry({
    required this.name,
    required this.path,
    this.size = 0,
  });
}
