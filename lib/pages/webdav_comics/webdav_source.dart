/// WebDAV Comics Source Module
///
/// Built-in native comic source (not a JS config). Registered at app init as
/// [WebDavBuiltinSource] so it appears in Explore / Comic Sources and uses the
/// standard [ComicPage] detail UI.
///
/// Features:
/// - Browse comic directories on WebDAV server
/// - Stream images on-demand during reading (Range for CBZ)
/// - Cache loaded images
/// - Directory comics + chapter subdirectories + archives
///
/// Architecture:
/// - [WebDavBuiltinSource] - ComicSource adapter (loadInfo / loadEp / explore)
/// - [WebDavComicClient] - WebDAV API
/// - [WebDavProvider] - state + streaming + cache
/// - [WebDavImageProvider] - ImageProvider
/// - [WebDavComicsPage] - directory browser
/// - [WebDavSettingsPage] - server config
library;

export 'webdav_accounts.dart';
export 'webdav_builtin_source.dart';
export 'webdav_client.dart';
export 'webdav_comics_page.dart';
export 'webdav_image_provider.dart';
export 'webdav_models.dart';
export 'webdav_provider.dart';
export 'webdav_settings_page.dart';
export 'streaming_zip.dart';
