/// WebDAV Comics Source Module
///
/// Provides the ability to browse and read comics directly from a WebDAV server
/// without downloading them to local storage first.
///
/// Features:
/// - Browse comic directories on WebDAV server
/// - Stream images on-demand during reading
/// - Cache loaded images for smooth re-reading
/// - Support directory-based comics and chapter subdirectories
/// - Natural sorting of files and chapters
///
/// Architecture:
/// - [WebDavComicClient] - Low-level WebDAV API operations
/// - [WebDavProvider] - State management and caching layer
/// - [WebDavImageProvider] - Flutter ImageProvider for streaming
/// - [WebDavComicsPage] - Browse UI
/// - [WebDavSettingsPage] - Configuration UI

library webdav_comics;

export 'webdav_client.dart';
export 'webdav_comics_page.dart';
export 'webdav_image_provider.dart';
export 'webdav_models.dart';
export 'webdav_provider.dart';
export 'webdav_settings_page.dart';
export 'streaming_zip.dart';
