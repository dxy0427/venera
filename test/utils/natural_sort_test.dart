import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webdav_comics/comic_info.dart';
import 'package:venera/utils/natural_sort.dart';

void main() {
  group('naturalComparePath', () {
    test('keeps each folder contiguous instead of interleaving', () {
      final entries = [
        '第2话/001.jpg',
        '第1话/010.jpg',
        '第2话/002.jpg',
        '第1话/002.jpg',
        '第1话/001.jpg',
      ];

      entries.sort(naturalComparePath);

      expect(entries, [
        '第1话/001.jpg',
        '第1话/002.jpg',
        '第1话/010.jpg',
        '第2话/001.jpg',
        '第2话/002.jpg',
      ]);
    });

    test('sorts root files before folders', () {
      final entries = ['第1话/001.jpg', 'cover.jpg'];

      entries.sort(naturalComparePath);

      expect(entries, ['cover.jpg', '第1话/001.jpg']);
    });

    test('orders nested folders naturally', () {
      final entries = [
        '卷10/001.jpg',
        '卷2/001.jpg',
        '卷2/子章2/001.jpg',
        '卷2/子章1/001.jpg',
      ];

      entries.sort(naturalComparePath);

      expect(entries, [
        '卷2/001.jpg',
        '卷2/子章1/001.jpg',
        '卷2/子章2/001.jpg',
        '卷10/001.jpg',
      ]);
    });

    test('does not treat dots in folder names as file extensions', () {
      final entries = ['Vol.10/001.jpg', 'Vol.2/001.jpg'];

      entries.sort(naturalComparePath);

      expect(entries, ['Vol.2/001.jpg', 'Vol.10/001.jpg']);
    });
  });

  group('naturalCompare', () {
    test('places the finale before the afterword', () {
      final chapters = ['后记', '第71话', '最终话'];

      chapters.sort(naturalCompare);

      expect(chapters, ['第71话', '最终话', '后记']);
    });

    test('keeps prologue first and extras last', () {
      final chapters = ['番外', '第2话', '预告', '最终话', '第10话'];

      chapters.sort(naturalCompare);

      expect(chapters, ['预告', '第2话', '第10话', '最终话', '番外']);
    });

    test('sorts numbered chapters naturally', () {
      final chapters = ['第10话', '第2话', '第1话'];

      chapters.sort(naturalCompare);

      expect(chapters, ['第1话', '第2话', '第10话']);
    });

    test('handles traditional finale variants', () {
      final chapters = ['後記', '最終話', '第3话'];

      chapters.sort(naturalCompare);

      expect(chapters, ['第3话', '最終話', '後記']);
    });
  });

  group('ComicInfo', () {
    test('splits multiple authors into separate values', () {
      final info = ComicInfo.fromJson(const {'author': '作者A, 作者B、作者C'});

      expect(info.authors, ['作者A', '作者B', '作者C']);
    });

    test('keeps a single author unchanged', () {
      final info = ComicInfo.fromJson(const {'author': '  作者A  '});

      expect(info.authors, ['作者A']);
    });

    test('returns no authors when the field is missing', () {
      final info = ComicInfo.fromJson(const {});

      expect(info.authors, isEmpty);
    });

    test('reads the optional update time', () {
      final info = ComicInfo.fromJson(const {'updateTime': '2024-05-01'});

      expect(info.updateTime, '2024-05-01');
      expect(info.isEmpty, isFalse);
    });

    test('preserves tag order and allows custom fields', () {
      final info = ComicInfo.fromJson(const {
        'author': '作者',
        'tags': {
          '题材': ['题材1', '题材2'],
          '状态': ['连载中'],
          '地区': ['韩国'],
          '热度': ['180595'],
        },
      });

      expect(info.authors, ['作者']);
      expect(info.detailTags.keys, ['题材', '状态', '地区', '热度']);
      expect(info.detailTags['题材'], ['题材1', '题材2']);
      expect(info.detailTags['地区'], ['韩国']);
    });
  });
}
