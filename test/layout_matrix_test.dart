import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';

import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/explore_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/pages/webdav_comics/webdav_comics_page.dart';
import 'package:venera/pages/webdav_comics/webdav_provider.dart';
import 'package:venera/pages/webdav_comics/webdav_settings_page.dart';

import 'support/app_test_harness.dart';

/// Pages that can be built without a live comic source or a loaded comic.
/// Each is rendered under every layout case; any RenderFlex overflow or
/// malformed semantics node fails the test.
final _pages = <String, Widget Function()>{
  'AggregatedSearchPage': () => const AggregatedSearchPage(keyword: 'test'),
  'CategoriesPage': () => const CategoriesPage(),
  'CategoryComicsPage': () =>
      const CategoryComicsPage(category: 'test', categoryKey: 'test'),
  'ComicSourcePage': () => const ComicSourcePage(),
  'DownloadingPage': () => const DownloadingPage(),
  'ExplorePage': () => const ExplorePage(),
  'FavoritesPage': () => const FavoritesPage(),
  'FollowUpdatesPage': () => const FollowUpdatesPage(),
  'HistoryPage': () => const HistoryPage(),
  'HomePage': () => const HomePage(),
  'LocalComicsPage': () => const LocalComicsPage(),
  'RankingPage': () => const RankingPage(categoryKey: 'test'),
  'SearchPage': () => const SearchPage(),
  'SearchResultPage': () =>
      const SearchResultPage(text: 'test', sourceKey: 'test'),
  'SettingsPage': () => const SettingsPage(),
  'AboutSettings': () => const AboutSettings(),
  'AppearanceSettings': () => const AppearanceSettings(),
  'LocalFavoritesSettings': () => const LocalFavoritesSettings(),
  'ReaderSettings': () => const ReaderSettings(),
  'UpdatesSettings': () => const UpdatesSettings(),
  'WebDavSettingsPage': () => const WebDavSettingsPage(),
  'WebDavComicsPage': () => const WebDavComicsPage(accountId: 'layout-test'),
};

void main() {
  setUpAll(() async {
    await initAppForTest();
  });

  for (final entry in _pages.entries) {
    for (final config in layoutCases) {
      final name = '${entry.key} lays out on ${config.name}';
      testWidgets(name, (tester) async {
        if (entry.key == 'WebDavComicsPage') {
          // An incomplete account exercises the setup UI without networking.
          final previous = appdata.settings['webdavComicAccounts'];
          appdata.settings['webdavComicAccounts'] = [
            {'id': 'layout-test', 'name': 'Layout test', 'url': ''},
          ];
          addTearDown(() {
            WebDavProvider.release('layout-test');
            appdata.settings['webdavComicAccounts'] = previous;
          });
        }
        final error = await renderPage(
          tester,
          entry.value(),
          config: config,
          navigationShell: entry.key == 'ExplorePage',
          expectedText:
              const {
                'AggregatedSearchPage',
                'CategoryComicsPage',
                'ExplorePage',
                'RankingPage',
                'SearchResultPage',
              }.contains(entry.key)
              ? 'Layout sample comic'
              : null,
        );
        expect(
          error,
          isNull,
          reason:
              '${entry.key} threw while rendering at ${config.name}: $error',
        );
      });
    }
  }
}
