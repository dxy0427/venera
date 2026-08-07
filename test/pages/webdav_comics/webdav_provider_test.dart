import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/webdav_comics/streaming_zip.dart';
import 'package:venera/pages/webdav_comics/webdav_accounts.dart';
import 'package:venera/pages/webdav_comics/webdav_client.dart';
import 'package:venera/pages/webdav_comics/webdav_provider.dart';
import 'package:venera/pages/webdav_comics/webdav_references.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  late Directory dataDir;
  late Directory cacheDir;

  setUpAll(() {
    dataDir = Directory.systemTemp.createTempSync('webdav-provider-data-');
    cacheDir = Directory.systemTemp.createTempSync('webdav-provider-cache-');
    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;
  });

  setUp(() {
    appdata.settings['webdavComicAccounts'] = [
      WebDavAccount(
        id: 'test',
        name: 'Test',
        url: 'https://example.com/dav',
        user: 'user',
        pass: 'pass',
      ).toJson(),
    ];
    appdata.settings['webdavComicActiveId'] = 'test';
  });

  tearDownAll(() {
    try {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    } on FileSystemException {
      // CacheManager keeps its SQLite handle open for the process lifetime.
    }
  });

  test('merges concurrent initialization for the same archive', () async {
    final client = _FakeWebDavComicClient();
    final listCompleter = Completer<List<ZipEntryInfo>>();
    var readerCount = 0;
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
      streamingReaderFactory:
          ({required webdavUrl, required user, required pass, knownFileSize}) {
            readerCount++;
            return _FakeStreamingZipReader(
              webdavUrl: webdavUrl,
              listEntriesResult: listCompleter.future,
            );
          },
    );

    final first = provider.getComicImages(
      WebDavResourceRef.comic('test', '/comic.cbz').encode(),
    );
    final second = provider.getComicImages(
      WebDavResourceRef.comic('test', '/comic.cbz').encode(),
    );
    await Future<void>.delayed(Duration.zero);

    expect(readerCount, 1);

    listCompleter.complete(const [
      ZipEntryInfo(
        fileName: '001.jpg',
        compressedSize: 4,
        uncompressedSize: 4,
        isDirectory: false,
      ),
    ]);
    final results = await Future.wait([first, second]);

    expect(results[0], results[1]);
    expect(readerCount, 1);
  });

  test('ignores an older directory request that finishes last', () async {
    final client = _FakeWebDavComicClient();
    final oldRequest = Completer<List<dynamic>>();
    final newRequest = Completer<List<dynamic>>();
    client.directoryResults['/old/'] = oldRequest.future;
    client.directoryResults['/new/'] = newRequest.future;
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
    );

    final oldLoad = provider.loadDirectory('/old/');
    final newLoad = provider.loadDirectory('/new/');
    newRequest.complete([webdav.File(name: 'new.cbz', size: 2)]);
    await newLoad;
    oldRequest.complete([webdav.File(name: 'old.cbz', size: 1)]);
    await oldLoad;

    expect(provider.directoryEntries, hasLength(1));
    expect(provider.directoryEntries!.single.path, '/new/new.cbz');
  });

  test('retries info.json after a transient failure', () async {
    final client = _FakeWebDavComicClient()
      ..imageResults.addError(TimeoutException('temporary timeout'))
      ..imageResults.add(
        Uint8List.fromList(utf8.encode('{"title":"Retried"}')),
      );
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
    );
    final comic = WebDavResourceRef.comic('test', '/force-refresh/').encode();

    expect(await provider.loadComicInfo(comic), isNull);
    final retried = await provider.loadComicInfo(comic);

    expect(retried?.title, 'Retried');
    expect(client.imageReadCount, 2);
  });

  test('keeps a confirmed missing info.json from being refetched', () async {
    final client = _FakeWebDavComicClient()
      ..imageResults.addError(Exception('404 Not found'));
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
    );
    final comic = WebDavResourceRef.comic('test', '/missing/').encode();

    expect(await provider.loadComicInfo(comic), isNull);
    expect(await provider.loadComicInfo(comic), isNull);

    expect(client.imageReadCount, 1);
  });

  test('force refresh bypasses a cached info.json response', () async {
    final client = _FakeWebDavComicClient()
      ..imageResults.add(Uint8List.fromList(utf8.encode('{"title":"Old"}')))
      ..imageResults.add(Uint8List.fromList(utf8.encode('{"title":"New"}')));
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
    );
    final comic = WebDavResourceRef.comic('test', '/comic/').encode();

    expect((await provider.loadComicInfo(comic))?.title, 'Old');
    expect(
      (await provider.loadComicInfo(comic, forceRefresh: true))?.title,
      'New',
    );
    expect(client.imageReadCount, 2);
  });

  test('force refresh keeps cached info after a transient failure', () async {
    final client = _FakeWebDavComicClient()
      ..imageResults.add(Uint8List.fromList(utf8.encode('{"title":"Cached"}')))
      ..imageResults.addError(TimeoutException('temporary timeout'));
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
    );
    final comic = WebDavResourceRef.comic('test', '/cached-fallback/').encode();

    expect((await provider.loadComicInfo(comic))?.title, 'Cached');
    expect(
      (await provider.loadComicInfo(comic, forceRefresh: true))?.title,
      'Cached',
    );
    expect(client.imageReadCount, 2);
  });

  test('modified date ignores cover and metadata changes', () async {
    final client = _FakeWebDavComicClient();
    client.directoryResults['/comic/'] = Future.value([
      webdav.File(name: 'cover.jpg', mTime: DateTime.utc(2026, 3, 1)),
      webdav.File(name: 'info.json', mTime: DateTime.utc(2026, 2, 1)),
      webdav.File(name: 'chapter.cbz', mTime: DateTime.utc(2026, 1, 1)),
    ]);
    final provider = WebDavProvider.forTesting(
      accountId: 'test',
      client: client,
    );

    expect(
      await provider.loadModifiedDate('/comic/', forceRefresh: true),
      '2026-01-01',
    );
    expect(client.forceRefreshCount, 1);
  });

  test(
    'directory with only cover and metadata has no update fallback',
    () async {
      final client = _FakeWebDavComicClient();
      client.directoryResults['/empty-comic/'] = Future.value([
        webdav.File(name: 'cover.jpg', mTime: DateTime.utc(2026, 3, 1)),
        webdav.File(name: 'info.json', mTime: DateTime.utc(2026, 2, 1)),
      ]);
      final provider = WebDavProvider.forTesting(
        accountId: 'test',
        client: client,
      );

      expect(
        await provider.loadModifiedDate('/empty-comic/', forceRefresh: true),
        isNull,
      );
    },
  );
}

class _FakeWebDavComicClient extends WebDavComicClient {
  _FakeWebDavComicClient()
    : super(
        WebDavAccount(
          id: 'test',
          name: 'Test',
          url: 'https://example.com/dav',
          user: 'user',
          pass: 'pass',
        ),
      );

  final Map<String, Future<List<dynamic>>> directoryResults = {};
  final _QueuedResults<Uint8List> imageResults = _QueuedResults();
  int imageReadCount = 0;
  int forceRefreshCount = 0;

  @override
  Future<List<dynamic>> readDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) forceRefreshCount++;
    return directoryResults[path] ?? const <dynamic>[];
  }

  @override
  Future<bool> isComicDirectory(String path) async => false;

  @override
  Future<Uint8List> readImage(String path) async {
    imageReadCount++;
    return imageResults.take();
  }
}

class _QueuedResults<T> {
  final List<Object> _values = [];

  void add(T value) => _values.add(value as Object);

  void addError(Object error) => _values.add(_QueuedError(error));

  Future<T> take() async {
    final value = _values.removeAt(0);
    if (value is _QueuedError) throw value.error;
    return value as T;
  }
}

class _QueuedError {
  final Object error;

  const _QueuedError(this.error);
}

class _FakeStreamingZipReader extends StreamingZipReader {
  _FakeStreamingZipReader({
    required super.webdavUrl,
    required this.listEntriesResult,
  }) : super(user: '', pass: '');

  final Future<List<ZipEntryInfo>> listEntriesResult;

  @override
  Future<List<ZipEntryInfo>> listEntries() => listEntriesResult;

  @override
  void dispose() {}
}
