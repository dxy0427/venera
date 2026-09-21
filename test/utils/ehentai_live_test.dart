import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/js_engine.dart';

/// Live end-to-end test for the ehentai source against the real
/// e-hentai.org (no account required).
///
/// Reproduces the reader scenario "jump straight to a middle page":
/// it resolves a middle page's image independently of pages 1..N-1,
/// through the exact chain the app uses (loadThumbnails -> getKey ->
/// imagedispatch API -> image download), with a real QuickJS engine,
/// real DOM parsing and real network requests.
///
/// Skips automatically when e-hentai.org is unreachable (e.g. CI).
void main() {
  var networkOk = true;
  FlutterQjs? engine;

  final settings = <String, dynamic>{
    'domain': 'e-hentai.org',
    'archiveBotApiKey': 'test-key',
    'archiveBotAutoCheckin': true,
  };
  final savedData = <String, dynamic>{};

  Map<String, dynamic> asStringKeyedMap(Map<dynamic, dynamic> m) =>
      m.map((k, v) => MapEntry(k.toString(), v));

  const chromeUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  Future<Map<String, dynamic>> realHttp(Map<String, dynamic> req) async {
    String? error;
    HttpClientResponse? response;
    Uint8List? bodyBytes;
    try {
      var method = (req['http_method'] ?? 'GET').toString().toUpperCase();
      var url = Uri.parse(req['url'].toString());
      var headers = <String, String>{};
      (req['headers'] as Map?)?.forEach((k, v) {
        var key = k.toString().toLowerCase();
        // App-internal meta options must not hit the wire.
        if (key == 'cache-time' || key == 'prevent-parallel') return;
        headers[key] = v.toString();
      });
      headers.putIfAbsent('user-agent', () => chromeUA);
      var client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
      var request = await client.openUrl(method, url).timeout(
        const Duration(seconds: 20),
      );
      headers.forEach((k, v) {
        if (k != 'content-type') {
          request.headers.set(k, v);
        }
      });
      var data = req['data'];
      if (data != null) {
        String body;
        if (data is Map || data is List) {
          body = jsonEncode(data);
        } else {
          body = data.toString();
        }
        request.headers.contentLength = utf8.encode(body).length;
        request.add(utf8.encode(body));
      }
      response = await request.close().timeout(const Duration(seconds: 20));
      bodyBytes = await response
          .fold(<int>[], (List<int> previous, List<int> chunk) {
            previous.addAll(chunk);
            return previous;
          })
          .timeout(const Duration(seconds: 60))
          .then((list) => Uint8List.fromList(list));
      client.close();
    } catch (e) {
      error = e.toString();
    }
    var responseHeaders = <String, String>{};
    response?.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(',');
    });
    dynamic body = req['bytes'] == true
        ? bodyBytes
        : (bodyBytes != null
              ? utf8.decode(bodyBytes, allowMalformed: true)
              : null);
    return {
      'status': response?.statusCode,
      'headers': responseHeaders,
      'body': body,
      'error': error,
    };
  }

  Object? messageReceiver(dynamic message) {
    if (message is Map) {
      switch (message['method']) {
        case 'getLocale':
          return 'zh_CN';
        case 'delay':
          return Future.delayed(Duration(milliseconds: message['time'] as int));
        case 'load_setting':
          return settings[message['setting_key']];
        case 'load_data':
          return savedData[message['data_key']];
        case 'save_data':
          savedData[message['data_key']] = message['data'];
          return null;
        case 'http':
          return realHttp(asStringKeyedMap(message));
        case 'html':
          // Real DOM parsing: delegate to the app's own implementation.
          return JsEngine().handleHtmlCallback(asStringKeyedMap(message));
        case 'UI':
          if (message['function'] == 'showSelectDialog') {
            return Future.value(0);
          }
          return null;
        case 'cookie':
          return message['function'] == 'get' ? <dynamic>[] : null;
        default:
          return null;
      }
    }
    return null;
  }

  setUpAll(() async {
    try {
      var client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      var request = await client
          .openUrl('GET', Uri.parse('https://e-hentai.org/'))
          .timeout(const Duration(seconds: 15));
      var response = await request.close().timeout(const Duration(seconds: 15));
      await response.drain<void>();
      client.close();
      expect(response.statusCode, anyOf(200, 302));
    } catch (e) {
      networkOk = false;
      // ignore: avoid_print
      print('Skip: e-hentai.org unreachable: $e');
    }
    if (!networkOk) return;

    engine = FlutterQjs();
    engine!.dispatch();
    var setGlobalFunc = engine!.evaluate(
      "(key, value) => { this[key] = value; }",
    );
    (setGlobalFunc as JSInvokable)(["sendMessage", messageReceiver]);
    setGlobalFunc.free();
    var initJs = File('assets/init.js').readAsStringSync();
    engine!.evaluate(initJs, name: "<init>");

    var js = File('ehentai.js').readAsStringSync().replaceAll("\r\n", "\n");
    String? line1;
    for (var line in js.split('\n')) {
      if (line.trim().startsWith("class ")) {
        line1 = line;
        break;
      }
    }
    expect(line1, isNotNull, reason: 'class declaration not found');
    var className = line1!
        .split("class")[1]
        .split("extends ComicSource")
        .first
        .trim();
    engine!.evaluate(
      "(() => { $js\n this['source'] = new $className()\n }).call()",
      name: className,
    );
    expect(engine!.evaluate("this['source'].name"), 'ehentai');
  });

  tearDownAll(() {
    engine?.close();
  });

  test(
    'jumping to a middle page resolves and downloads independently',
    () async {
      if (!networkOk) return;
      var jsResult = await engine!.evaluate('''
        (async () => {
          const src = this['source'];
          const list = await src.explore[0].loadNext(null);
          if (!list || !list.comics || list.comics.length === 0) {
            return JSON.stringify({error: "no galleries in latest list"});
          }
          const comic = list.comics[0];
          const ep = await src.comic.loadEp(comic.id);
          const n = ep.images.length;
          if (n < 4) {
            return JSON.stringify({error: "gallery too short: " + n});
          }
          const mid = Math.floor(n / 2);
          const first = await src.comic.onImageLoad(ep.images[0], comic.id, null);
          const middle = await src.comic.onImageLoad(ep.images[mid], comic.id, null);
          return JSON.stringify({
            comicId: comic.id,
            maxPage: n,
            midIndex: mid,
            firstUrl: first.url,
            middleUrl: middle.url,
            middleReferer: middle.headers ? middle.headers.referer : null,
            hasMiddleRetry: typeof middle.onLoadFailed === "function",
          });
        })()
      ''');
      var data = jsonDecode(jsResult.toString()) as Map<String, dynamic>;
      expect(data['error'], isNull, reason: 'source chain failed: ${data['error']}');
      expect(data['comicId'], contains('e-hentai.org/g/'));
      expect(data['maxPage'], greaterThanOrEqualTo(4));
      var midIndex = data['midIndex'] as int;
      expect(midIndex, greaterThan(0), reason: 'not a middle page');
      expect(data['firstUrl'], isNotEmpty);
      expect(data['middleUrl'], isNotEmpty);
      expect(data['middleUrl'], isNot(equals(data['firstUrl'])));
      expect(data['hasMiddleRetry'], isTrue,
          reason: 'middle page must provide the nl retry callback');

      // Download the resolved middle image with the returned referer and
      // verify it is a real image, exactly as the reader would.
      var request = await HttpClient()
          .openUrl('GET', Uri.parse(data['middleUrl'] as String))
          .timeout(const Duration(seconds: 20));
      request.headers.set('user-agent', chromeUA);
      var referer = data['middleReferer'] as String?;
      if (referer != null && referer.isNotEmpty) {
        request.headers.set('referer', referer);
      }
      var response = await request.close().timeout(const Duration(seconds: 20));
      var bytes = await response.fold(
        <int>[],
        (List<int> previous, List<int> chunk) {
          previous.addAll(chunk);
          return previous;
        },
      ).timeout(const Duration(seconds: 60));
      expect(response.statusCode, 200);
      expect(bytes.length, greaterThan(1024), reason: 'image too small');
      var isJpeg = bytes.length > 2 &&
          bytes[0] == 0xFF &&
          bytes[1] == 0xD8;
      var isPng = bytes.length > 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47;
      var isGif = bytes.length > 6 && bytes[0] == 0x47 && bytes[1] == 0x49;
      var isWebp = bytes.length > 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46;
      expect(isJpeg || isPng || isGif || isWebp, isTrue,
          reason: 'not a recognized image format');
      // ignore: avoid_print
      print(
        'gallery=${(data['comicId'] as String).split('/g/')[1]} '
        'pages=${data['maxPage']} loadedMiddlePage=${midIndex + 1} '
        'imageBytes=${bytes.length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
