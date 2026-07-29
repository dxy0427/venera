import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/utils/io.dart';

import 'webdav_image_provider.dart' as image_provider;
import 'webdav_accounts.dart';
import 'webdav_provider.dart';

/// Image provider that loads images from WebDAV server.
///
/// Uses the existing [CacheManager] for disk caching, so images
/// are only downloaded once and served from cache on subsequent reads.
class WebDavImageProvider
    extends BaseImageProvider<image_provider.WebDavImageProvider> {
  /// The WebDAV image path (with or without 'webdav://' prefix).
  final String path;

  /// Source key for identification.
  static const String sourceKey = 'webdav';

  const WebDavImageProvider(this.path);

  @override
  Future<WebDavImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    return WebDavProvider().loadImage(path);
  }

  @override
  String get key => '${WebDavAccounts.activeId() ?? 'default'}@$path';
}

/// Image provider specifically for WebDAV comic reader images.
/// Supports loading progress callbacks.
class WebDavReaderImageProvider
    extends BaseImageProvider<image_provider.WebDavReaderImageProvider> {
  final String path;
  final int page;
  final void Function()? onLoadFailed;

  const WebDavReaderImageProvider(
    this.path, {
    required this.page,
    this.onLoadFailed,
  });

  @override
  Future<WebDavReaderImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture(this);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    return WebDavProvider().loadImage(path);
  }

  @override
  void onLoadError() {
    onLoadFailed?.call();
  }

  @override
  String get key => '${WebDavAccounts.activeId() ?? 'default'}@$path@$page';
}
