import 'dart:async';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/pages/webdav_comics/webdav_provider.dart';
import 'package:venera/pages/webdav_comics/webdav_references.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/local_cbz.dart';

import 'app_dio.dart';
import 'source_request_context.dart';

abstract class ImageDownloader {
  @visibleForTesting
  static Dio Function(BaseOptions options)? httpClientFactory;

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = _cacheKey(url, sourceKey, cid);
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      if (data.isEmpty) {
        // An empty entry fails decoding and would trap every retry.
        await CacheManager().delete(cacheKey);
      } else {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      }
    }

    if ((url.startsWith('localcbz://') ||
            sourceKey == 'webdav' ||
            url.startsWith('webdav://') ||
            url.startsWith('stream://') ||
            url.startsWith('file://')) &&
        !url.startsWith('http://') &&
        !url.startsWith('https://')) {
      final bytes = await loadSpecialImageBytes(url);
      if (bytes.isEmpty) {
        throw "Error: Empty image data.";
      }
      await CacheManager().writeCache(cacheKey, bytes);
      yield ImageDownloadProgress(
        currentBytes: bytes.length,
        totalBytes: bytes.length,
        imageBytes: bytes,
      );
      return;
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    if (buffer.isEmpty) {
      throw "Error: Empty image data.";
    }
    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values.toList()) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  static void cancelComicImages(String? sourceKey, String cid, String eid) {
    for (final wrapper in _loadingImages.values.toList()) {
      if (wrapper.group == (sourceKey, cid, eid)) wrapper.cancel();
    }
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = _cacheKey(imageKey, sourceKey, '$cid@$eid');
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid, cancelToken: cancelToken),
      (wrapper) {
        // An old cancelled request can finish after a replacement has started.
        if (identical(_loadingImages[cacheKey], wrapper)) {
          _loadingImages.remove(cacheKey);
        }
      },
      cancelToken,
      (sourceKey, cid, eid),
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static String _cacheKey(String value, String? sourceKey, String? suffix) {
    return '$value@$sourceKey${suffix == null ? '' : '@$suffix'}';
  }

  /// The cache key used by [loadComicImage] and [loadThumbnail] for [value].
  /// Image providers use it to invalidate corrupted downloads on
  /// decode failure, so a retry fetches fresh data.
  static String cacheKeyFor(String value, String? sourceKey, String? suffix) {
    return _cacheKey(value, sourceKey, suffix);
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) {
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      cancelToken: cancelToken,
    );
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) async* {
    final context = SourceRequestContext(cancelToken ?? CancelToken());
    try {
      yield* _loadComicImageWithContext(imageKey, sourceKey, cid, eid, context);
    } catch (_) {
      // JS rejections are strings. Preserve cancellation as a typed error so
      // the image provider does not retry or display it as a network failure.
      _checkCancelled(context.cancelToken);
      rethrow;
    } finally {
      context.dispose();
    }
  }

  static Stream<ImageDownloadProgress> _loadComicImageWithContext(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    SourceRequestContext context,
  ) async* {
    final cancelToken = context.cancelToken;
    _checkCancelled(cancelToken);
    // WebDAV owns its disk cache and invalidation keys; don't duplicate pages.
    if (imageKey.startsWith('webdav://') || imageKey.startsWith('stream://')) {
      final bytes = await loadSpecialImageBytes(
        imageKey,
        cancelToken: cancelToken,
      );
      _checkCancelled(cancelToken);
      if (bytes.isEmpty) throw 'Error: Empty image data.';
      yield ImageDownloadProgress(
        currentBytes: bytes.length,
        totalBytes: bytes.length,
        imageBytes: bytes,
      );
      return;
    }
    final cacheKey = _cacheKey(imageKey, sourceKey, '$cid@$eid');
    final cache = await CacheManager().findCache(cacheKey);
    _checkCancelled(cancelToken);

    if (cache != null) {
      var data = await cache.readAsBytes();
      if (data.isEmpty) {
        // An empty entry fails decoding and would trap every retry.
        await CacheManager().delete(cacheKey);
      } else {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      }
    }

    // Local CBZ entries and extracted local images.
    if ((imageKey.startsWith('localcbz://') ||
            sourceKey == 'webdav' ||
            imageKey.startsWith('file://')) &&
        !imageKey.startsWith('http://') &&
        !imageKey.startsWith('https://')) {
      try {
        final bytes = await loadSpecialImageBytes(
          imageKey,
          cancelToken: cancelToken,
        );
        _checkCancelled(cancelToken);
        if (bytes.isEmpty) {
          throw "Error: Empty image data.";
        }
        await CacheManager().writeCache(cacheKey, bytes);
        yield ImageDownloadProgress(
          currentBytes: bytes.length,
          totalBytes: bytes.length,
          imageBytes: bytes,
        );
        return;
      } catch (e) {
        _checkCancelled(cancelToken);
        throw "Special image load failed: $e";
      }
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource == null) {
        throw "Comic source is no longer available.";
      }
      configs =
          (await comicSource.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
            requestId: context.id,
          )) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        _checkCancelled(cancelToken);
        var dio = (httpClientFactory ?? AppDio.new)(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
          cancelToken: cancelToken,
        );
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          _checkCancelled(cancelToken);
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([
            Uint8List.fromList(buffer),
          ]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        if (data.isEmpty) {
          throw "Error: Empty image data.";
        }
        _checkCancelled(cancelToken);
        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        _checkCancelled(cancelToken);
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled == true) throw token!.cancelError!;
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController<T>> controllers = [];

  final CancelToken cancelToken;
  final (String?, String, String) group;

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed, this.cancelToken, this.group) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
      if (controllers.isEmpty && !isClosed) cancel();
    };
    return controller.stream;
  }

  void cancel() {
    if (isClosed) return;
    isClosed = true;
    cancelToken.cancel('Reader image request cancelled');
    for (var controller in controllers) {
      controller.addError(cancelToken.cancelError!);
      controller.close();
    }
    controllers.clear();
    onClosed(this);
  }
}

Future<Uint8List> loadSpecialImageBytes(
  String imageKey, {
  CancelToken? cancelToken,
}) async {
  if (imageKey.startsWith('file://')) {
    return File(imageKey.substring(7)).readAsBytes();
  }
  if (imageKey.startsWith('localcbz://')) {
    return LocalCbzReader.readReference(imageKey);
  }
  final ref = WebDavResourceRef.parse(imageKey);
  return WebDavProvider.forAccount(
    ref.accountId,
  ).loadImage(imageKey, cancelToken: cancelToken);
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
