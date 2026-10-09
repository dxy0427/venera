import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_theme.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

class _LoginSource implements ComicSource {
  @override
  final data = <String, dynamic>{};

  int saves = 0;

  @override
  Future<void> saveData() async => saves++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  testWidgets('cookie inputs and web login coexist after the page split', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _LoginSource();
    const fields = ['ipb_member_id', 'ipb_pass_hash', 'igneous', 'star'];
    List<String>? submitted;
    final config = AccountConfig(
      null,
      'https://forums.e-hentai.org/index.php?act=Login&CODE=00',
      null,
      () {},
      (_, title) => title == 'E-Hentai Forums',
      () {},
      fields,
      (values) async {
        submitted = values;
        return true;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(
          primary: Colors.blue,
          secondary: Colors.green,
          tertiary: Colors.orange,
          brightness: Brightness.light,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ComicSourceLoginPage(config: config, source: source),
                ),
              ),
              child: const Text('Open login'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();
    expect(find.text('Login with webview'.tl), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Login with webview'.tl),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.byType(TextField), findsNWidgets(4));
    for (var i = 0; i < fields.length; i++) {
      final input = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == fields[i],
      );
      expect(input, findsOneWidget);
      expect(tester.widget<TextField>(input).obscureText, isTrue);
      // Synthetic values for the UI callback; no network login is performed.
      await tester.enterText(input, 'fixture-$i');
    }
    await tester.tap(find.text('Continue'.tl));
    await tester.pumpAndSettle();
    expect(submitted, ['fixture-0', 'fixture-1', 'fixture-2', 'fixture-3']);
    expect(source.data['account'], 'ok');
    expect(source.saves, 1);
    expect(find.byType(ComicSourceLoginPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
