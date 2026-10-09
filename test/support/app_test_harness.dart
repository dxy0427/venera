import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_theme.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';

import 'package:venera/foundation/read_later.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/data_sync.dart';

import 'layout_source.dart';

/// Routes every path_provider lookup at a throwaway temp directory so pages
/// that persist state can initialise inside the test VM.
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getTemporaryPath() async => dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getApplicationCachePath() async => dir;

  @override
  Future<String?> getLibraryPath() async => dir;

  @override
  Future<String?> getExternalStoragePath() async => dir;

  @override
  Future<String?> getDownloadsPath() async => dir;
}

bool _initialised = false;

/// Brings up the minimum set of app state pages need to build: translations,
/// a data directory, and the SQLite-backed managers. Safe to call repeatedly.
Future<void> initAppForTest() async {
  if (_initialised) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  await AppTranslation.init();
  final dir = Directory.systemTemp.createTempSync('venera_layout_test');
  PathProviderPlatform.instance = _TempPathProvider(dir.path);
  App.dataPath = dir.path;
  App.cachePath = dir.path;
  App.version = '0.0.0-test';
  // Manager inits await appdata.ensureInit(), which only completes once
  // doInit() has run (normally App.init() does this). Drive it directly.
  await appdata.init();
  // Several pages read these as non-null lists; their shipped default is null.
  appdata.settings['searchSources'] = <String>['test'];
  appdata.settings['explore_pages'] = <String>['Layout explore'];
  appdata.settings['categories'] = <String>['test'];
  appdata.settings['quickFavorite'] = 'No';
  DataSync.instance = DataSync.forTesting();
  await HistoryManager().init();
  await LocalFavoritesManager().init();
  LocalManager().initForTesting(dir.path);
  await ReadLaterManager().init();
  final image = await createTestImage(width: 120, height: 180);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final cover = File('${dir.path}/layout-cover.png');
  await cover.writeAsBytes(bytes!.buffer.asUint8List());
  ComicSourceManager().add(createLayoutSource(cover.uri.toString()));
  _initialised = true;
}

/// A window/text configuration to render a page under.
class LayoutCase {
  const LayoutCase(this.name, this.size, this.textScale, {this.dark = false});

  final String name;
  final Size size;
  final double textScale;
  final bool dark;

  @override
  String toString() => name;
}

/// The configurations that actually catch layout defects: a narrow phone, the
/// same phone at the maximum supported font scale, and a wide desktop window
/// also at maximum scale.
const layoutCases = <LayoutCase>[
  LayoutCase('phone', Size(400, 800), 1.0),
  LayoutCase('phone@1.3', Size(400, 800), 1.3),
  LayoutCase('desktop@1.3', Size(1400, 900), 1.3, dark: true),
];

/// Renders [page] inside the real app theme with the semantics tree enabled,
/// so both RenderFlex overflows and invalid SemanticsNode configurations
/// surface as test failures instead of only appearing at runtime.
///
/// Returns any exception captured while rendering; `null` means the page laid
/// out cleanly.
Future<Object?> renderPage(
  WidgetTester tester,
  Widget page, {
  required LayoutCase config,
  bool navigationShell = false,
  String? expectedText,
}) async {
  tester.view.physicalSize = config.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final handle = tester.ensureSemantics();

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(
        primary: Colors.blue,
        secondary: Colors.green,
        tertiary: Colors.orange,
        brightness: config.dark ? Brightness.dark : Brightness.light,
      ),
      darkTheme: AppTheme.build(
        primary: Colors.blue,
        secondary: Colors.green,
        tertiary: Colors.orange,
        brightness: Brightness.dark,
      ),
      themeMode: config.dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(textScaler: TextScaler.linear(config.textScale)),
          child: child!,
        );
      },
      home: navigationShell
          ? NaviPane(
              paneItems: [
                PaneItemEntry(
                  label: 'Explore',
                  icon: Icons.explore_outlined,
                  activeIcon: Icons.explore,
                ),
              ],
              paneActions: const [],
              pageBuilder: (_) => page,
              observer: NaviObserver(),
              navigatorKey: GlobalKey<NavigatorState>(),
            )
          : Scaffold(body: page),
    ),
  );
  // Let async state settle; pages that load data render a placeholder first.
  // Search history and local cover files use real disk I/O, which cannot
  // complete just by advancing the widget test's fake clock.
  var storageFlushed = false;
  final storage = appdata.saveData(false).whenComplete(() {
    storageFlushed = true;
  });
  for (var i = 0; i < 100 && !storageFlushed; i++) {
    // Let the OS finish writes, then service the fake-zone callbacks and the
    // saveData lock's 20ms retry. Awaiting that lock inside runAsync deadlocks.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(storageFlushed, isTrue, reason: 'page storage writes did not finish');
  await storage;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final error = tester.takeException();
  if (expectedText != null) {
    expect(find.textContaining(expectedText), findsWidgets);
  }
  // Tear the tree down so any debounce/delayed work the page started is
  // cancelled; the framework fails a test that leaves a timer pending, and an
  // undrained timer from one case can surface in the next.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
  // Dispose before the test framework's end-of-test semantics check runs;
  // addTearDown would run too late.
  handle.dispose();
  return error;
}
