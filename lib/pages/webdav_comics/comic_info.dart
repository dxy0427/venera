import 'dart:convert';
import 'dart:io';

/// Metadata loaded from an `info.json` file in a comic directory.
///
/// Supported fields:
/// ```json
/// {
///   "title": "漫画名",
///   "author": "作者A, 作者B",
///   "description": "简介",
///   "tags": {
///     "题材": ["后宫", "穿越"],
///     "年份": ["2024"],
///     "语言": ["中文"]
///   },
///   "cover": "cover.jpg",
///   "stars": 4.5,
///   "updateTime": "2024-05-01"
/// }
/// ```
class ComicInfo {
  static const _authorNamespaces = {'author', 'authors', '作者'};

  static const _genreNamespaces = {'genre', 'genres', '题材', '題材'};

  static const _yearNamespaces = {'year', '年份'};

  static const _languageNamespaces = {'language', 'languages', '语言', '語言'};

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

  /// Authors split on common separators, so multiple authors become
  /// individual tags instead of a single long value.
  List<String> get authors {
    final raw = author?.trim();
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split(RegExp(r'[,，;；、/]|\s{2,}'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Information namespaces displayed by the built-in local and WebDAV
  /// sources. Their detail pages intentionally mirror online sources that
  /// expose author rather than a separate artist/subtitle row.
  Map<String, List<String>> get detailTags {
    final result = <String, List<String>>{};

    List<String> collect(Iterable<String> namespaces) {
      final values = <String>[];
      for (final entry in tags.entries) {
        final namespace = entry.key.trim().toLowerCase();
        if (!namespaces.contains(namespace)) continue;
        values.addAll(entry.value);
      }
      return values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList();
    }

    final authorValues = <String>{...authors, ...collect(_authorNamespaces)};
    if (authorValues.isNotEmpty) {
      result['Author'] = authorValues.toList();
    }
    final genreValues = collect(_genreNamespaces);
    if (genreValues.isNotEmpty) result['Genre'] = genreValues;
    final yearValues = collect(_yearNamespaces);
    if (yearValues.isNotEmpty) result['Year'] = yearValues;
    final languageValues = collect(_languageNamespaces);
    if (languageValues.isNotEmpty) result['Language'] = languageValues;
    return result;
  }

  /// Parse from a JSON file on disk.
  static Future<ComicInfo?> fromFile(File file) async {
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
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
