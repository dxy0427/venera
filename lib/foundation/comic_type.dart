import 'package:venera/foundation/comic_source/comic_source.dart';

class ComicType {
  final int value;

  const ComicType(this.value);

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  static const webdav = ComicType(-999);

  String get sourceKey {
    if (this == local) {
      return "local";
    } else if (this == webdav) {
      return "webdav";
    } else {
      // Keep old favorites/history usable after their source is deleted.
      return comicSource?.key ?? "Unknown:$value";
    }
  }

  ComicSource? get comicSource {
    if (this == local) {
      return null;
    } else if (this == webdav) {
      return ComicSource.find("webdav");
    } else {
      return ComicSource.fromIntKey(value);
    }
  }

  static const local = ComicType(0);

  factory ComicType.fromKey(String key) {
    if (key == "local") {
      return local;
    } else if (key == "webdav") {
      return webdav;
    } else if (key.startsWith('Unknown:')) {
      final value = int.tryParse(key.substring('Unknown:'.length));
      if (value != null) return ComicType(value);
    } else {
      return ComicType(key.hashCode);
    }
    return ComicType(key.hashCode);
  }
}
