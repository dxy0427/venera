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

  Object? messageReceiver(dynamic message) {
    if (message is Map) {
      switch (message["method"]) {
        case 'getLocale':
          return 'zh_CN';
        case 'delay':
          return Future.delayed(Duration(milliseconds: message["time"]));
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
    () {
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

      // Archive bot settings and functions must exist.
      expect(
        engine!.evaluate("this['temp'].settings['archiveBotApiKey'] != null"),
        isTrue,
      );
      expect(
        engine!.evaluate("typeof this['temp'].comic.archive.getDownloadUrl"),
        'function',
      );
    },
    skip: libAvailable ? false : 'libflutter_qjs_plugin.so not available',
  );
}
