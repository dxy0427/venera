import 'dart:collection';

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

/// Native, deterministic source data for page layouts. Real JS/network source
/// behavior is exercised by the separate source and opt-in live tests.
ComicSource createLayoutSource(String cover) {
  final comics = [
    Comic(
      'Layout sample comic',
      cover,
      'layout-comic',
      'Sample author',
      ['genre:adventure'],
      'A sample description for layout checks.',
      'test',
      12,
      'en',
    ),
  ];
  Future<Res<List<Comic>>> load(int page) async => Res(comics, subData: 1);
  return ComicSource(
    'Layout source',
    'test',
    null, // account
    const CategoryData(
      title: 'Layout categories',
      key: 'test',
      categories: [],
      enableRankingPage: true,
    ),
    CategoryComicsData(
      options: [
        CategoryComicsOptions(
          'Sort',
          LinkedHashMap.of({'latest': 'Latest', 'popular': 'Popular'}),
          [],
          null,
        ),
      ],
      load: (_, _, _, page) => load(page),
      rankingData: RankingData(
        {'weekly': 'Weekly', 'monthly': 'Monthly'},
        (_, page) => load(page),
        null,
      ),
    ),
    null, // favorites
    [
      ExplorePageData(
        'Layout explore',
        ExplorePageType.multiPageComicList,
        load,
        null,
        null,
        null,
      ),
    ],
    SearchPageData([], (_, page, _) => load(page), null),
    null, // settings
    null, // comic info
    null, // thumbnail loader
    null, // pages
    null, // image config
    null, // thumbnail config
    'layout-test.js',
    '', // update URL
    '1.0.0',
    null, // comments
    null, // send comment
    null, // chapter comments
    null, // send chapter comment
    null, // like comic
    null, // vote comment
    null, // like comment
    null, // ID matcher
    null, // translations
    null, // tag click
    null, // tag suggestion selection
    null, // link handler
    false, // tag suggestions
    false, // tag translation
    null, // star rating
    null, // archive downloader
  );
}
