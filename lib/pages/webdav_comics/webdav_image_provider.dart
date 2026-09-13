import 'dart:async' show Future;
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';

import 'webdav_image_provider.dart' as image_provider;
import 'webdav_provider.dart';
import 'webdav_references.dart';

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

  String get accountId => WebDavResourceRef.parse(path).accountId;

  @override
  Future<WebDavImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    if (path.startsWith('file://')) {
      return File(path.substring(7)).readAsBytes();
    }
    return WebDavProvider.forAccount(accountId).loadImage(path);
  }

  @override
  String get key => path;
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

  String get accountId => WebDavResourceRef.parse(path).accountId;

  @override
  Future<WebDavReaderImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture(this);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    if (path.startsWith('file://')) {
      return File(path.substring(7)).readAsBytes();
    }
    return WebDavProvider.forAccount(accountId).loadImage(path);
  }

  @override
  void onLoadError() {
    onLoadFailed?.call();
  }

  @override
  String get key => '$path@$page';
}
