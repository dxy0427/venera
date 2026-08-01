part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    var comicSource = ComicSource.find(widget.sourceKey);
    var history = HistoryManager().find(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    if (widget.sourceKey == 'webdav') {
      try {
        final ref = WebDavResourceRef.parse(widget.id);
        final provider = WebDavProvider.forAccount(ref.accountId);
        final path = ref.remotePath;
        final name = path.split('/').where((s) => s.isNotEmpty).last;
        ComicChapters? chapters;
        if (path.endsWith('/')) {
          final chapterList = await provider.getChapters(path);
          if (chapterList.isNotEmpty) {
            final map = <String, String>{};
            for (final c in chapterList) {
              map[WebDavResourceRef.chapter(ref.accountId, c.path).encode()] =
                  c.name;
            }
            chapters = ComicChapters(map);
          }
        }
        final model = _WebDavReaderHistoryModel(
          title: name,
          cover: history?.cover ?? '',
          id: widget.id,
          maxPage: history?.maxPage,
        );
        return Res(
          ReaderProps(
            type: ComicType.webdav,
            cid: widget.id,
            name: name,
            chapters: chapters,
            history: history ?? History.fromModel(model: model, ep: 0, page: 0),
            author: '',
            tags: const [],
          ),
        );
      } catch (e) {
        return Res.error(e.toString());
      }
    }
    if (comicSource == null) {
      var localComic = LocalManager().find(
        widget.id,
        ComicType.fromKey(widget.sourceKey),
      );
      if (localComic == null) {
        return Res.error("comic not found");
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history:
              history ?? History.fromModel(model: localComic, ep: 0, page: 0),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    } else {
      var comic = await comicSource.loadComicInfo!(widget.id);
      if (comic.error) {
        return Res.fromErrorRes(comic);
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: comic.data.title,
          chapters: comic.data.chapters,
          history:
              history ?? History.fromModel(model: comic.data, ep: 0, page: 0),
          author: comic.data.findAuthor() ?? "",
          tags: comic.data.plainTags,
        ),
      );
    }
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}

class _WebDavReaderHistoryModel with HistoryMixin {
  @override
  final String title;

  @override
  final String cover;

  @override
  final String id;

  @override
  final int? maxPage;

  const _WebDavReaderHistoryModel({
    required this.title,
    required this.cover,
    required this.id,
    this.maxPage,
  });

  @override
  String? get subTitle => null;

  @override
  HistoryType get historyType => ComicType.webdav;
}
