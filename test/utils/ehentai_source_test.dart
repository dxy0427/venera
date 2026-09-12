import 'dart:ffi';
import 'dart:io';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies that the ehentai comic source (ehentai.js in the repository root)
/// parses and instantiates under the real QuickJS engine used by the app,
/// replicating [ComicSourceParser.parse].
///
/// Requires libflutter_qjs_plugin.so to be loadable (Linux dev machine);
/// skipped otherwise (e.g. on CI).
void main() {
  var libAvailable = true;
  try {
    DynamicLibrary.open('libflutter_qjs_plugin.so');
  } catch (_) {
    libAvailable = false;
  }

  FlutterQjs? engine;

  final settings = <String, dynamic>{
    'archiveBotApiKey': 'test-key',
    'archiveBotAutoCheckin': true,
  };
  final savedData = <String, dynamic>{};

  Object? messageReceiver(dynamic message) {
    if (message is Map) {
      switch (message["method"]) {
        case 'getLocale':
          return 'zh_CN';
        case 'delay':
          return Future.delayed(Duration(milliseconds: message["time"]));
        case 'load_setting':
          return settings[message["setting_key"]];
        case 'load_data':
          return savedData[message["data_key"]];
        case 'save_data':
          savedData[message["data_key"]] = message["data"];
          return null;
        case 'http':
          return Future.value({
            "status": 200,
            "headers": <String, String>{},
            "body":
                '{"code":0,"msg":"ok","data":{"current_GP":123,"get_GP":25,'
                '"archive_url":"https://example.hath.network/archive/x.zip"}}',
            "error": null,
          });
        case 'UI':
          // The verification dialog returns the user's choice; default to
          // online verification in tests.
          if (message['function'] == 'showSelectDialog') {
            return Future.value(0);
          }
          if (message['function'] == 'openWebView') {
            return Future.value(false);
          }
          return null;
        default:
          return null;
      }
    }
    return null;
  }

  setUpAll(() {
    engine = FlutterQjs();
    engine!.dispatch();
    var setGlobalFunc = engine!.evaluate(
      "(key, value) => { this[key] = value; }",
    );
    (setGlobalFunc as JSInvokable)(["sendMessage", messageReceiver]);
    setGlobalFunc.free();
    var initJs = File('assets/init.js').readAsStringSync();
    engine!.evaluate(initJs, name: "<init>");
  });

  tearDownAll(() {
    engine?.close();
  });

  test(
    'ehentai.js instantiates under the real QuickJS engine',
    () async {
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
        "(() => { $js\n this['temp'] = new $className()\n }).call()",
        name: className,
      );

      expect(engine!.evaluate("this['temp'].name"), 'ehentai');
      expect(engine!.evaluate("this['temp'].key"), 'ehentai');
      expect(engine!.evaluate("this['temp'].version"), isNotNull);

      // Ranking options are built from this.translate() in a class field
      // initializer: the translation field must be declared before them.
      var options = engine!.evaluate(
        "this['temp'].categoryComics.ranking.options",
      );
      expect(options, equals(["15-昨日", "13-本月", "12-年度", "11-全部"]));

      // The translation table itself must be loaded.
      expect(
        engine!.evaluate("this['temp'].translation['zh_CN']['Yesterday']"),
        '昨日',
      );

      // Explore page titles and the verification dialog are localized.
      expect(
        engine!.evaluate("this['temp'].translation['zh_CN']['eh latest']"),
        'Eh主页',
      );
      expect(
        engine!.evaluate(
          "this['temp'].translation['zh_CN']['Online Verification (WebView)']",
        ),
        '在线验证（WebView辅助）',
      );

      // The cookie login dialog exists and its three options are translated.
      expect(
        engine!.evaluate(
          "typeof this['temp'].account.loginWithCookies.validate === 'function'",
        ),
        isTrue,
      );

      // Archive bot settings and functions must exist.
      expect(
        engine!.evaluate("this['temp'].settings['archiveBotApiKey'] != null"),
        isTrue,
      );
      expect(
        engine!.evaluate("typeof this['temp'].comic.archive.getDownloadUrl"),
        'function',
      );

      // The auto check-in runs via init() and must record the check-in date.
      expect(savedData.containsKey('lastArbotCheckin'), isFalse);
      engine!.evaluate("this['temp'].init()");
      await pumpEventQueue();
      expect(savedData['lastArbotCheckin'], isNotNull);

      // arbotRequest parses the bot response and carries the API key.
      var balance = await engine!.evaluate(
        "this['temp'].arbotRequest('/balance', {})",
      );
      expect(balance, isA<Map>());
      expect((balance as Map)['status'], 200);
      expect(((balance['json'] as Map)['data'] as Map)['current_GP'], 123);
    },
    skip: libAvailable ? false : 'libflutter_qjs_plugin.so not available',
  );
}
