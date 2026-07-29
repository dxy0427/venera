import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';

void main() {
  test('keeps deleted source types addressable', () {
    const type = ComicType(123456789);

    expect(type.sourceKey, 'Unknown:123456789');
    expect(ComicType.fromKey(type.sourceKey).value, type.value);
  });

  test('keeps built-in type keys unchanged', () {
    expect(ComicType.local.sourceKey, 'local');
    expect(ComicType.webdav.sourceKey, 'webdav');
  });
}
