import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webdav_comics/webdav_accounts.dart';
import 'package:venera/pages/webdav_comics/webdav_builtin_source.dart';
import 'package:venera/pages/webdav_comics/webdav_references.dart';

void main() {
  test('WebDAV resource references round-trip Unicode and URL characters', () {
    const accountId = '账号: A/B';
    const path = '/漫画 空格/卷:1/封面?x=1#页.jpg';
    final ref = WebDavResourceRef.image(accountId, path);

    expect(WebDavResourceRef.parse(ref.encode()), ref);
  });

  test('same remote path on two accounts has different identity', () {
    final first = WebDavResourceRef.comic('one', '/same/path').encode();
    final second = WebDavResourceRef.comic('two', '/same/path').encode();

    expect(first, isNot(second));
    expect(WebDavResourceRef.parse(first).accountId, 'one');
    expect(WebDavResourceRef.parse(second).accountId, 'two');
  });

  test(
    'explore pages contain exactly valid accounts and stable unique titles',
    () {
      final accounts = [
        WebDavAccount(
          id: 'one',
          name: 'NAS',
          url: 'https://one',
          user: '',
          pass: '',
        ),
        WebDavAccount(
          id: 'two',
          name: 'NAS',
          url: 'https://two',
          user: '',
          pass: '',
        ),
        WebDavAccount(
          id: 'invalid',
          name: 'Offline',
          url: '',
          user: '',
          pass: '',
        ),
      ];

      final pages = WebDavBuiltinSource.explorePagesForAccounts(accounts);

      expect(pages, hasLength(2));
      expect(pages.map((page) => page.title).toSet(), hasLength(2));
      expect(
        pages.every((page) => page.title.startsWith('WebDAV · NAS')),
        true,
      );
    },
  );

  test('chapter and stream references preserve account identity', () {
    final chapter = WebDavResourceRef.chapter('account', '/comic/01/');
    final stream = WebDavResourceRef.stream(
      'account',
      '/comic/01.cbz',
      '图片: 01.jpg',
    );

    expect(WebDavResourceRef.parse(chapter.encode()).accountId, 'account');
    expect(WebDavResourceRef.parse(stream.encode()).accountId, 'account');
    expect(WebDavResourceRef.parse(stream.encode()).entryName, '图片: 01.jpg');
  });

  test('explore titles remain unique for colliding display names', () {
    final accounts = [
      WebDavAccount(
        id: 'B',
        name: 'NAS',
        url: 'https://one',
        user: '',
        pass: '',
      ),
      WebDavAccount(
        id: 'two',
        name: 'NAS · B',
        url: 'https://two',
        user: '',
        pass: '',
      ),
      WebDavAccount(
        id: 'three',
        name: 'NAS',
        url: 'https://three',
        user: '',
        pass: '',
      ),
    ];

    final titles = WebDavBuiltinSource.explorePagesForAccounts(
      accounts,
    ).map((page) => page.title).toList();

    expect(titles.toSet(), hasLength(titles.length));
  });
}
