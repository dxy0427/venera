import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/translations.dart';

// Real QuickJS + loopback HTTP. The normal JS route uses an injected dart:io
// transport because flutter test does not bundle the platform Rust library;
// the http_client header route exercises the app's dart:io factory directly.
class _MemoryCache implements CacheManager {
  final written = <String, List<int>>{};
  @override
  Future<File?> findCache(String key) async => null;
  @override
  Future<void> writeCache(String key, List<int> bytes, [int? duration]) async {
    written[key] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var available = true;
  try {
    DynamicLibrary.open('libflutter_qjs_plugin.so');
  } catch (_) {
    available = false;
  }
  late JsEngine engine;
  late Directory root;
  ComicSource? source;
  final clients = <AppDio>[];
  final cache = _MemoryCache();

  AppDio httpClient([BaseOptions? options]) {
    final dio = AppDio(options)..httpClientAdapter = IOHttpClientAdapter();
    clients.add(dio);
    return dio;
  }

  setUpAll(() async {
    if (!available) return;
    final oldHttpOverrides = HttpOverrides.current;
    HttpOverrides.global =
        null; // Use real sockets, not Flutter's HTTP 400 stub.
    addTearDown(() => HttpOverrides.global = oldHttpOverrides);
    await AppTranslation.init();
    root = await Directory.systemTemp.createTemp('eh-resolution-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    App.version = '1.16.0';
    final oldCache = CacheManager.instance;
    final oldProxy = appdata.settings['proxy'];
    addTearDown(() {
      CacheManager.instance = oldCache;
      appdata.settings['proxy'] = oldProxy;
    });
    CacheManager.instance = cache;
    appdata.settings['proxy'] = 'direct';
    engine = JsEngine();
    engine.setHttpClientForTesting(
      httpClient(
        BaseOptions(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      ),
    );
    await engine.init();
    engine.runCode('''
      (() => {
        ${File('ehentai.js').readAsStringSync()}
        globalThis.ehUnderTest = new Ehentai();
      })();
    ''');
    // Parse the real bridge while exposing only the EH image entry point;
    // account/explore callbacks and daily check-in are unrelated to this test.
    source = await ComicSourceParser().parse('''
class EhCancellationTestSource extends ComicSource {
  name = "EH cancellation test";
  key = "ehentai";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {};
  settings = {domain: {title: "Domain", type: "input", default: "e-hentai.org"}};
  comic = {onImageLoad: (...args) => ehUnderTest.comic.onImageLoad(...args)};
}
''', '${root.path}/ehentai.js');
    ComicSourceManager().add(source!);
    ImageDownloader.httpClientFactory = httpClient;
    engine.runCode('''
      globalThis.testDartIo = false;
      const originalSend = Network.sendRequest;
      Network.sendRequest = function(method, url, headers, data, extra) {
        return originalSend.call(this, method, url,
          testDartIo ? {...headers, http_client: 'dart:io'} : headers, data, extra);
      };
      void 0;
    ''');
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });

  tearDownAll(() async {
    if (!available) return;
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.httpClientFactory = null;
    if (source != null) ComicSourceManager().remove(source!.key);
    for (final client in clients) {
      client.close(force: true);
    }
    engine.dispose();
    await root.delete(recursive: true);
  });

  for (final dartIo in [false, true]) {
    for (final stage in ['gallery', 'key', 'api', 'retry']) {
      test(
        'real EH/QuickJS cancels $stage requests (dart:io=$dartIo) independently',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final base = 'http://127.0.0.1:${server.port}';
          final comic = '$base/g/1/token/';
          final otherComic = '$base/g/2/token/';
          final stalled = Completer<void>();
          final disconnected = Completer<void>();
          final requests = <String>[];
          engine.runCode('''
          testDartIo = $dartIo;
          Object.defineProperty(ehUnderTest, 'apiUrl',
            {value: ${jsonEncode('$base/api')}, configurable: true});
          void 0;
        ''');
          server.listen((request) async {
            final path = request.uri.path;
            var kind = path.startsWith('/g/')
                ? 'gallery'
                : path.startsWith('/s/')
                ? 'key'
                : path == '/api'
                ? 'api'
                : 'image';
            var gid = path.startsWith('/g/')
                ? int.parse(path.split('/')[2])
                : path.startsWith('/s/')
                ? int.parse(path.split('/').last.split('-').first)
                : path.startsWith('/image/')
                ? int.parse(path.split('/').last)
                : 0;
            if (kind == 'api') {
              final body =
                  jsonDecode(await utf8.decoder.bind(request).join()) as Map;
              gid = int.parse(body['gid'].toString());
              if (body['nl'] != null) kind = 'retry';
            }
            requests.add('$gid:$kind');
            if (gid == 1 && kind == stage) {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              // Deliberately no headers/body: cancel must also stop waiting for
              // an address-resolution server which has not responded at all.
              void closed() {
                socket.destroy();
                if (!disconnected.isCompleted) disconnected.complete();
              }

              socket.listen(
                (_) {},
                onDone: closed,
                onError: (Object error) {
                  if (error is! SocketException) throw error;
                  closed();
                },
              );
              stalled.complete();
              return;
            }
            if (kind == 'gallery') {
              request.response.write(
                '<div class="gdtl"><a><img src="$base/thumb"></a></div><div id="gdt"><a href="$base/s/key/$gid-1">page</a></div>',
              );
            } else if (kind == 'key') {
              request.response.write(
                '<script>var showkey="synthetic";</script>',
              );
            } else if (kind == 'api' || kind == 'retry') {
              request.response.write(
                jsonEncode({
                  'i6': "nl('again')",
                  'i3': '<img src="$base/image/$gid" style="">',
                }),
              );
            } else if (stage == 'retry' && gid == 1) {
              request.response.statusCode = 503;
            } else {
              request.response.add([1, 2, 3, 4]);
            }
            await request.response.close();
          });
          final cancelled = expectLater(
            ImageDownloader.loadComicImage(
              '0',
              'ehentai',
              comic,
              '0',
            ).drain<void>(),
            throwsA(
              isA<DioException>().having(
                (e) => e.type,
                'type',
                DioExceptionType.cancel,
              ),
            ),
          );
          await stalled.future.timeout(const Duration(seconds: 5));
          final unaffected = ImageDownloader.loadComicImage(
            '0',
            'ehentai',
            otherComic,
            '0',
          ).last;
          ImageDownloader.cancelComicImages('ehentai', comic, '0');
          await cancelled;
          await disconnected.future.timeout(const Duration(seconds: 3));
          expect((await unaffected).imageBytes, [1, 2, 3, 4]);
          expect(
            requests.where((request) => request == '1:image').length,
            stage == 'retry' ? 1 : 0,
          );
          expect(cache.written.containsKey('0@ehentai@$comic@0'), isFalse);
        },
        skip: available ? false : 'libflutter_qjs_plugin.so not available',
      );
    }
  }
}
