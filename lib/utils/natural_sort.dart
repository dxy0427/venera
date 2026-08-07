/// Natural / chapter-aware string ordering.
///
/// Ordering groups:
/// 0. prologue / preview (预告, 序章, ...)
/// 1. numbered / normal chapters (第0话, 第1话, 01, ...)
/// 2. finale of the main story (最终话, 终章, 完结, ...)
/// 3. afterword / extras (后记, 番外, 特典, ...)
///
/// Within the same group, compare by extracted chapter number when present,
/// otherwise by mixed text+number natural order.
int naturalCompare(String a, String b) {
  return _naturalCompare(a, b, stripExtension: true);
}

int _naturalCompare(String a, String b, {required bool stripExtension}) {
  final nameA = stripExtension ? _stripExtension(a) : a;
  final nameB = stripExtension ? _stripExtension(b) : b;

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

/// Compare archive entry paths, grouping entries by directory.
///
/// A flat [naturalCompare] on full paths interleaves images from different
/// folders, because it extracts the first number found anywhere in the path:
/// `b/002.jpg` would sort before `a/010.jpg`. Comparing segment by segment
/// keeps every folder's images contiguous and in natural order.
///
/// At the same depth, files sort before subdirectories.
int naturalComparePath(String a, String b) {
  final aParts = a.split('/').where((e) => e.isNotEmpty).toList();
  final bParts = b.split('/').where((e) => e.isNotEmpty).toList();
  final minLen = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (int i = 0; i < minLen; i++) {
    final aIsLeaf = i == aParts.length - 1;
    final bIsLeaf = i == bParts.length - 1;
    if (aIsLeaf != bIsLeaf) return aIsLeaf ? -1 : 1;
    final cmp = _naturalCompare(
      aParts[i],
      bParts[i],
      stripExtension: aIsLeaf && bIsLeaf,
    );
    if (cmp != 0) return cmp;
  }
  return aParts.length.compareTo(bParts.length);
}

String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

/// Finale of the main story: sorts after regular chapters but before extras.
const _chapterTokensFinale = [
  '最终话',
  '最終话',
  '最终話',
  '最終話',
  '终章',
  '終章',
  '完结',
  '完結',
  'final',
  'finale',
];

/// Special chapter names that should sort AFTER the finale.
const _chapterTokensAfter = [
  '后记',
  '後記',
  '后日谈',
  '後日談',
  '番外',
  '特典',
  '附录',
  '附錄',
  'afterword',
  'epilogue',
  'extra',
  'bonus',
  'omake',
  'special',
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

/// 0 = before (预告), 1 = normal, 2 = finale (最终话), 3 = after (后记/番外)
int _chapterGroup(String name) {
  final lower = name.toLowerCase();
  for (final token in _chapterTokensBefore) {
    if (lower.contains(token)) return 0;
  }
  for (final token in _chapterTokensAfter) {
    if (lower.contains(token)) return 3;
  }
  for (final token in _chapterTokensFinale) {
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
