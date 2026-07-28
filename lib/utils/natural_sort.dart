/// Natural / chapter-aware string ordering.
///
/// Ordering groups:
/// 0. prologue / preview (预告, 序章, ...)
/// 1. numbered / normal chapters (第0话, 第1话, 01, ...)
/// 2. afterword / extras (后记, 最终话, 番外, ...)
///
/// Within the same group, compare by extracted chapter number when present,
/// otherwise by mixed text+number natural order.
int naturalCompare(String a, String b) {
  final nameA = _stripExtension(a);
  final nameB = _stripExtension(b);

  final groupA = _chapterGroup(nameA);
  final groupB = _chapterGroup(nameB);
  if (groupA != groupB) return groupA.compareTo(groupB);

  final numA = _extractChapterNumber(nameA);
  final numB = _extractChapterNumber(nameB);
  if (numA >= 0 && numB >= 0) {
    final byNum = numA.compareTo(numB);
    if (byNum != 0) return byNum;
  } else if (numA >= 0 && numB < 0) {
    return -1;
  } else if (numA < 0 && numB >= 0) {
    return 1;
  }

  final aParts = _splitNatural(nameA);
  final bParts = _splitNatural(nameB);
  final minLen = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (int i = 0; i < minLen; i++) {
    final aIsNum = int.tryParse(aParts[i]) != null;
    final bIsNum = int.tryParse(bParts[i]) != null;
    if (aIsNum && bIsNum) {
      final cmp = int.parse(aParts[i]).compareTo(int.parse(bParts[i]));
      if (cmp != 0) return cmp;
    } else {
      final cmp = aParts[i].toLowerCase().compareTo(bParts[i].toLowerCase());
      if (cmp != 0) return cmp;
    }
  }
  return aParts.length.compareTo(bParts.length);
}

String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

/// Special chapter names that should sort AFTER regular chapters.
const _chapterTokensAfter = [
  '后记',
  '后日谈',
  '最终话',
  '终章',
  '完结',
  '番外',
  '特典',
  '附录',
  'afterword',
  'epilogue',
  'extra',
  'bonus',
  'omake',
  'special',
  'final',
];

/// Special chapter names that should sort BEFORE regular chapters.
const _chapterTokensBefore = [
  '预告',
  '预览',
  'preview',
  'prologue',
  '序章',
  '序幕',
  '前言',
];

/// 0 = before (预告), 1 = normal, 2 = after (后记/最终话)
int _chapterGroup(String name) {
  final lower = name.toLowerCase();
  for (final token in _chapterTokensBefore) {
    if (lower.contains(token)) return 0;
  }
  for (final token in _chapterTokensAfter) {
    if (lower.contains(token)) return 2;
  }
  return 1;
}

/// Extract a chapter number, or -1 if none.
int _extractChapterNumber(String name) {
  final leading = RegExp(r'^(\d+)').firstMatch(name);
  if (leading != null) return int.parse(leading.group(1)!);

  final cn = RegExp(r'第\s*(\d+)\s*[话話回卷章]').firstMatch(name);
  if (cn != null) return int.parse(cn.group(1)!);

  final ep = RegExp(
    r'(?:ep|ch|chapter|vol|volume)[.\s_-]*(\d+)',
    caseSensitive: false,
  ).firstMatch(name);
  if (ep != null) return int.parse(ep.group(1)!);

  final any = RegExp(r'(\d+)').firstMatch(name);
  if (any != null) return int.parse(any.group(1)!);

  return -1;
}

List<String> _splitNatural(String s) {
  final parts = <String>[];
  final buffer = StringBuffer();
  bool? wasDigit;
  for (int i = 0; i < s.length; i++) {
    final isDigit = s[i].codeUnitAt(0) >= 48 && s[i].codeUnitAt(0) <= 57;
    if (wasDigit != null && isDigit != wasDigit) {
      parts.add(buffer.toString());
      buffer.clear();
    }
    buffer.write(s[i]);
    wasDigit = isDigit;
  }
  if (buffer.isNotEmpty) parts.add(buffer.toString());
  return parts;
}
