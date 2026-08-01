import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/webdav_comics/webdav_provider.dart';
import 'package:venera/pages/webdav_comics/webdav_references.dart';
import 'package:venera/utils/io.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    // Handle file:// URLs directly
    if (url.startsWith('file://')) {
      var file = File(url.substring(7));
      if (await file.exists()) {
        return file.readAsBytes();
      }
    }
    // WebDAV covers (remote path / stream / webdav://)
    if (history.type == ComicType.webdav) {
      checkStop();
      final comicRef = WebDavResourceRef.parse(history.id);
      var cover = url.isNotEmpty && WebDavResourceRef.isReference(url)
          ? url
          : WebDavResourceRef.stream(
              comicRef.accountId,
              comicRef.remotePath,
            ).encode();
      return WebDavProvider.forAccount(comicRef.accountId).loadImage(cover);
    }
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
      var comicSource = history.type.comicSource;
      if (comicSource == null || comicSource.loadComicInfo == null) {
        throw "Comic source is no longer available.";
      }
      var comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      url = comic.data.cover;
      history.cover = url;
      HistoryManager().addHistory(history);
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key {
    return "history${history.id}${history.type.value}";
  }
}
