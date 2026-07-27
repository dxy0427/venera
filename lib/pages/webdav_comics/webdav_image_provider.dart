import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';

import 'webdav_provider.dart';

/// Image provider that loads images from WebDAV server.
///
/// Uses the existing [CacheManager] for disk caching, so images
/// are only downloaded once and served from cache on subsequent reads.
class WebDavImageProvider extends ImageProvider<WebDavImageProvider> {
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
  ImageStreamCompleter loadImage(
    WebDavImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('image provider', this),
      ],
    );
  }

  Future<Codec> _loadAsync(
    WebDavImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final data = await WebDavProvider().loadImage(key.path);
      final buffer = await ImmutableBuffer.fromUint8List(data);
      return decode(buffer);
    } catch (e, s) {
      Log.error("WebDavImage", "Failed to load image ${key.path}: $e\n$s");
      rethrow;
    }
  }

  @override
  String get key => path;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WebDavImageProvider && other.path == path;
  }

  @override
  int get hashCode => path.hashCode;
}

/// Image provider specifically for WebDAV comic reader images.
/// Supports loading progress callbacks.
class WebDavReaderImageProvider extends ImageProvider<WebDavReaderImageProvider> {
  final String path;
  final int page;
  final void Function()? onLoadFailed;

  const WebDavReaderImageProvider(
    this.path, {
    required this.page,
    this.onLoadFailed,
  });

  @override
  Future<WebDavReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    WebDavReaderImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('image provider', this),
      ],
    );
  }

  Future<Codec> _loadAsync(
    WebDavReaderImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final data = await WebDavProvider().loadImage(key.path);
      final buffer = await ImmutableBuffer.fromUint8List(data);
      return decode(buffer);
    } catch (e, s) {
      Log.error("WebDavReaderImage", "Failed to load image: $e\n$s");
      onLoadFailed?.call();
      rethrow;
    }
  }

  @override
  String get key => '$path@$page';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WebDavReaderImageProvider &&
        other.path == path &&
        other.page == page;
  }

  @override
  int get hashCode => Object.hash(path, page);
}
