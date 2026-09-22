import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/js_engine.dart';

/// Opt-in source/network smoke test (no account required):
/// VENERA_EHENTAI_LIVE_TEST=1 flutter test test/utils/ehentai_live_test.dart
///
/// Uses real QuickJS, the app's DOM bridge and dart:io HTTP. Reader widget
/// regressions are covered separately in test/pages/reader. Native QuickJS
/// must be loadable; an explicitly enabled run fails on network/native errors.
void main() {
  final enabled = Platform.environment['VENERA_EHENTAI_LIVE_TEST'] == '1';

  test(
    'resolve a middle page first, download with progress and decode it',
    () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      addTearDown(() => client.close(force: true));
      final engine = FlutterQjs()..dispatch();
      addTearDown(engine.close);
      final dom = JsEngine();
      addTearDown(dom.dispose);
      final savedData = <String, dynamic>{};
      final settings = {
        'domain': 'e-hentai.org',
        'archiveBotAutoCheckin': false,
      };
      final apiPages = <int>[];
      const userAgent =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

      Future<Map<String, dynamic>> request(Map<String, dynamic> req) async {
        final uri = Uri.parse(req['url'] as String);
        final responseRequest = await client
            .openUrl(req['http_method'] as String? ?? 'GET', uri)
            .timeout(const Duration(seconds: 20));
        responseRequest.headers.set('user-agent', userAgent);
        (req['headers'] as Map?)?.forEach((key, value) {
          if (key != 'cache-time' && key != 'prevent-parallel') {
            responseRequest.headers.set(key.toString(), value.toString());
          }
        });
        final data = req['data'];
        if (data is Map &&
            (data['method'] == 'showpage' ||
                data['method'] == 'imagedispatch')) {
          apiPages.add((data['page'] as num).toInt());
        }
        if (data != null) {
          final body = utf8.encode(data is String ? data : jsonEncode(data));
          responseRequest.contentLength = body.length;
          responseRequest.add(body);
        }
        final response = await responseRequest.close().timeout(
          const Duration(seconds: 20),
        );
        final bytes = BytesBuilder(copy: false);
        final progress = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          bytes.add(chunk);
          progress.add(bytes.length);
        }
        final body = bytes.takeBytes();
        final headers = <String, String>{};
        response.headers.forEach((key, values) {
          headers[key] = values.join(',');
        });
        return {
          'status': response.statusCode,
          'headers': headers,
          'body': req['bytes'] == true
              ? body
              : utf8.decode(body, allowMalformed: true),
          'error': null,
          'progress': progress,
          'contentLength': response.contentLength,
        };
      }

      Object? receiver(dynamic message) {
        final data = Map<String, dynamic>.from(message as Map);
        switch (data['method']) {
          case 'getLocale':
            return 'en_US';
          case 'isLogged':
            return false;
          case 'delay':
            return Future<void>.delayed(Duration(milliseconds: data['time']));
          case 'load_setting':
            return settings[data['setting_key']];
          case 'load_data':
            return savedData[data['data_key']];
          case 'save_data':
            savedData[data['data_key']] = data['data'];
            return null;
          case 'http':
            return request(data);
          case 'html':
            return dom.handleHtmlCallback(data);
          case 'cookie':
            return data['function'] == 'get' ? <dynamic>[] : null;
          default:
            throw UnsupportedError(
              'Unexpected live-test call: ${data['method']}',
            );
        }
      }

      final setGlobal =
          engine.evaluate('(key, value) => { this[key] = value; }')
              as JSInvokable;
      setGlobal(['sendMessage', receiver]);
      setGlobal.free();
      engine.evaluate(
        File('assets/init.js').readAsStringSync(),
        name: '<init>',
      );
      final js = File('ehentai.js').readAsStringSync();
      final className = RegExp(
        r'class\s+(\w+)\s+extends ComicSource',
      ).firstMatch(js)!.group(1)!;
      engine.evaluate(
        '(() => { $js\n this.source = new $className(); })()',
        name: className,
      );

      final gallery = Platform.environment['VENERA_EHENTAI_TEST_GALLERY'];
      final result = await engine.evaluate('''
        (async () => {
          let id = ${jsonEncode(gallery)};
          if (!id) {
            const list = await source.explore[0].loadNext(null);
            const comic = list.comics.find(c => c.maxPage >= 20 && c.maxPage <= 300);
            if (!comic) throw new Error('No suitable public gallery in latest list');
            id = comic.id;
          }
          const chapter = await source.comic.loadEp(id);
          if (chapter.images.length < 4) throw new Error('Gallery is too short');
          const middle = Math.floor(chapter.images.length / 2);
          // Resolve the middle first: no earlier image has been resolved yet.
          const config = await source.comic.onImageLoad(chapter.images[middle], id, '0');
          this.liveMiddle = config;
          return JSON.stringify({
            id, count: chapter.images.length, middle,
            url: config.url, headers: config.headers,
            retry: typeof config.onLoadFailed === 'function'
          });
        })()
      ''');
      final data = jsonDecode(result as String) as Map<String, dynamic>;
      expect(Uri.parse(data['id'] as String).host, 'e-hentai.org');
      expect(data['retry'], isTrue);
      expect(apiPages, [(data['middle'] as int) + 1]);

      Future<Map<String, dynamic>> download(String url, Map headers) {
        return request({'url': url, 'headers': headers, 'bytes': true});
      }

      Future<void> checkImage(Map<String, dynamic> response) async {
        expect(response['status'], 200);
        final bytes = response['body'] as Uint8List;
        final progress = response['progress'] as List<int>;
        expect(bytes, isNotEmpty);
        expect(progress, isNotEmpty);
        expect(progress.last, bytes.length);
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThan(progress[i - 1]));
        }
        final total = response['contentLength'] as int;
        if (total > 0) expect(bytes.length, total);
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          expect(frame.image.width, greaterThan(1));
          expect(frame.image.height, greaterThan(1));
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }

      final middleImage = await download(
        data['url'] as String,
        data['headers'] as Map,
      );
      await checkImage(middleImage);

      // Reusing the same resolved URL should be measured, not assumed to be
      // impossible. No extra API resolution is made for this second request.
      final again = await download(
        data['url'] as String,
        data['headers'] as Map,
      );
      await checkImage(again);
      expect(again['body'], orderedEquals(middleImage['body'] as Uint8List));
      expect(apiPages, [(data['middle'] as int) + 1]);

      final firstResult = await engine.evaluate('''
        (async () => {
          const config = await source.comic.onImageLoad('0', ${jsonEncode(data['id'])}, '0');
          return JSON.stringify({url: config.url, headers: config.headers});
        })()
      ''');
      final first = jsonDecode(firstResult as String) as Map<String, dynamic>;
      expect(first['url'], isNot(data['url']));
      await checkImage(
        await download(first['url'] as String, first['headers'] as Map),
      );
      expect(apiPages, [(data['middle'] as int) + 1, 1]);

      // ignore: avoid_print
      print(
        'pages=${data['count']} middlePage=${(data['middle'] as int) + 1} '
        'bytes=${(middleImage['body'] as Uint8List).length} '
        'contentLength=${middleImage['contentLength']} '
        'chunks=${(middleImage['progress'] as List).length} '
        'sameUrlSecondDownload=OK decoded=OK',
      );
    },
    skip: enabled
        ? false
        : 'Set VENERA_EHENTAI_LIVE_TEST=1 to use the public EH site',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
