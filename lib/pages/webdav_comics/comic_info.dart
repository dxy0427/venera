import 'dart:convert';
import 'dart:io';

/// Metadata loaded from an `info.json` file in a comic directory.
///
/// Supported fields:
/// ```json
/// {
///   "title": "漫画名",
///   "author": "作者",
///   "description": "简介",
///   "tags": {
///     "题材": ["题材1", "题材2"],
///     "状态": ["连载中"],
///     "年份": ["2025"],
///     "语言": ["中文"]
///   },
///   "cover": "cover.jpg",
///   "stars": 8.7
/// }
/// ```
class ComicInfo {
  final String? title;
  final String? author;
  final String? description;
  final Map<String, List<String>> tags;
  final String? cover;
  final double? stars;
  final String? updateTime;

  const ComicInfo({
    this.title,
    this.author,
    this.description,
    this.tags = const {},
    this.cover,
    this.stars,
    this.updateTime,
  });

  /// Authors split on common separators when individual values are needed.
  List<String> get authors {
    final raw = author?.trim();
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split(RegExp(r'[,，;；、/]|\s{2,}'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Tags preserve the order and names from `info.json`.
  Map<String, List<String>> get detailTags {
    final result = <String, List<String>>{};
    for (final entry in tags.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      final values = entry.value
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      if (values.isNotEmpty) result[key] = values;
    }
    return result;
  }

  /// Parse from a JSON file on disk.
  static Future<ComicInfo?> fromFile(File file) async {
    if (!await file.exists()) return null;
    try {
      final content = utf8.decode(await file.readAsBytes());
      final json = jsonDecode(content) as Map<String, dynamic>;
      return fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Parse from a JSON map.
  static ComicInfo fromJson(Map<String, dynamic> json) {
    // Parse tags
    Map<String, List<String>> tags = {};
    if (json['tags'] is Map) {
      for (var entry in (json['tags'] as Map).entries) {
        final key = entry.key.toString();
        if (entry.value is List) {
          tags[key] = List<String>.from(
            (entry.value as List).map((e) => e.toString()),
          );
        } else if (entry.value is String) {
          tags[key] = [entry.value.toString()];
        }
      }
    }

    // Parse stars: normalize to 0-5 scale
    // If value > 5, assume it's on a 10-point scale and convert
    double? stars = (json['stars'] as num?)?.toDouble();
    if (stars != null && stars > 5) {
      stars = stars / 2;
    }

    return ComicInfo(
      title: json['title'] as String?,
      author: json['author'] as String?,
      description: json['description'] as String?,
      tags: tags,
      cover: json['cover'] as String?,
      stars: stars,
      updateTime: (json['updateTime'] ?? json['update_time'])?.toString(),
    );
  }

  /// Whether this has any meaningful data.
  bool get isEmpty =>
      title == null &&
      author == null &&
      description == null &&
      tags.isEmpty &&
      cover == null &&
      stars == null &&
      updateTime == null;
}
