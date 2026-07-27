import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'package:venera/pages/webdav_comics/comic_info.dart';
import 'webdav_image_provider.dart';
import 'webdav_models.dart';
import 'webdav_provider.dart';

/// Sort mode for WebDAV comics.
enum WebDavSortMode {
  nameAsc('name_asc', 'Name ↑'),
  nameDesc('name_desc', 'Name ↓'),
  dateAsc('date_asc', 'Date ↑'),
  dateDesc('date_desc', 'Date ↓'),
  sizeAsc('size_asc', 'Size ↑'),
  sizeDesc('size_desc', 'Size ↓');

  final String key;
  final String label;
  const WebDavSortMode(this.key, this.label);
}

/// Breadcrumb segment for directory navigation.
class _PathSegment {
  final String name;
  final String path;
  const _PathSegment({required this.name, required this.path});
}

/// Main page for browsing WebDAV comics.
class WebDavComicsPage extends StatefulWidget {
  const WebDavComicsPage({super.key});

  @override
  State<WebDavComicsPage> createState() => _WebDavComicsPageState();
}

class _WebDavComicsPageState extends State<WebDavComicsPage> {
  WebDavSortMode _sortMode = WebDavSortMode.nameAsc;

  /// Current browsing path (null = root).
  String? _currentPath;

  /// Breadcrumb path segments.
  final List<_PathSegment> _breadcrumbs = [];
  @override
  void initState() {
    super.initState();
    WebDavProvider().addListener(_onUpdate);
    if (WebDavProvider().comics == null && !WebDavProvider().isLoading) {
      WebDavProvider().loadComics();
    }
  }

  void _navigateTo(String path, String name) {
    setState(() {
      _breadcrumbs.add(_PathSegment(name: name, path: _currentPath ?? ''));
      _currentPath = path;
    });
    WebDavProvider().loadDirectory(path);
  }

  void _navigateBack() {
    if (_breadcrumbs.isNotEmpty) {
      final prev = _breadcrumbs.removeLast();
      setState(() {
        _currentPath = prev.path.isEmpty ? null : prev.path;
      });
      if (_currentPath == null) {
        WebDavProvider().loadComics(forceRefresh: true);
      } else {
        WebDavProvider().loadDirectory(_currentPath!);
      }
    } else {
      context.pop();
    }
  }

  void _navigateToRoot() {
    setState(() {
      _breadcrumbs.clear();
      _currentPath = null;
    });
    WebDavProvider().loadComics(forceRefresh: true);
  }

  @override
  void dispose() {
    WebDavProvider().removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final provider = WebDavProvider();

    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: _breadcrumbs.isNotEmpty
                ? GestureDetector(
                    onTap: _navigateToRoot,
                    child: Text(
                      _breadcrumbs.last.name,
                      style: ts.s16.copyWith(
                        color: context.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  )
                : Text('WebDAV Comics'.tl),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _navigateBack,
            ),
            actions: [
              if (_breadcrumbs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.home),
                  onPressed: _navigateToRoot,
                  tooltip: 'Back to root'.tl,
                ),
              IconButton(
                icon: const Icon(Icons.sort),
                onPressed: _showSortDialog,
                tooltip: 'Sort'.tl,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  if (_currentPath != null) {
                    WebDavProvider().loadDirectory(_currentPath!);
                  } else {
                    provider.refresh();
                  }
                },
                tooltip: 'Refresh'.tl,
              ),
            ],
          ),
          if (provider.isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (provider.error != null)
            SliverFillRemaining(
              child: _buildError(provider.error!),
            )
          else if (_currentComics.isEmpty)
            SliverFillRemaining(
              child: _buildEmpty(),
            )
          else
            _buildComicGrid(_currentComics),
        ],
      ),
    );
  }

  Widget _buildError(String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text('Failed to load comics'.tl, style: ts.s18),
          const SizedBox(height: 8),
          Text(error, style: ts.s14, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => WebDavProvider().refresh(),
            child: Text('Retry'.tl),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_open, size: 48),
          const SizedBox(height: 16),
          Text('No comics found'.tl, style: ts.s18),
          const SizedBox(height: 8),
          Text(
            'Make sure the WebDAV path contains comic directories or archives.',
            style: ts.s14,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return ContentDialog(
              title: 'Sort'.tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: WebDavSortMode.values.map((mode) {
                  return RadioListTile<WebDavSortMode>(
                    title: Text(mode.label.tl),
                    value: mode,
                    groupValue: _sortMode,
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() => _sortMode = v);
                        setState(() {});
                        Navigator.pop(context);
                      }
                    },
                  );
                }).toList(),
              ),
            );
          },
        );
      },
    );
  }

  List<WebDavComicEntry> _sortComics(List<WebDavComicEntry> comics) {
    final sorted = List<WebDavComicEntry>.from(comics);
    // Category folders always come first
    sorted.sort((a, b) {
      if (a.isCategory && !b.isCategory) return -1;
      if (!a.isCategory && b.isCategory) return 1;
      // Then sort by selected mode
      switch (_sortMode) {
        case WebDavSortMode.nameAsc:
          return a.name.compareTo(b.name);
        case WebDavSortMode.nameDesc:
          return b.name.compareTo(a.name);
        case WebDavSortMode.dateAsc:
          return (a.modified ?? DateTime(2000))
              .compareTo(b.modified ?? DateTime(2000));
        case WebDavSortMode.dateDesc:
          return (b.modified ?? DateTime(2000))
              .compareTo(a.modified ?? DateTime(2000));
        case WebDavSortMode.sizeAsc:
          if (a.isDirectory && !b.isDirectory) return 1;
          if (!a.isDirectory && b.isDirectory) return -1;
          return a.size.compareTo(b.size);
        case WebDavSortMode.sizeDesc:
          if (a.isDirectory && !b.isDirectory) return 1;
          if (!a.isDirectory && b.isDirectory) return -1;
          return b.size.compareTo(a.size);
      }
    });
    return sorted;
  }

  Widget _buildComicGrid(List<WebDavComicEntry> comics) {
    final sorted = _sortComics(comics);
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.72,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index >= sorted.length) return null;
          return _WebDavComicCard(
            comic: sorted[index],
            onTap: () => _openComic(sorted[index]),
          );
        },
        childCount: sorted.length,
      ),
    );
  }

  List<WebDavComicEntry> get _currentComics {
    return WebDavProvider().directoryEntries ?? WebDavProvider().comics ?? [];
  }

  void _openComic(WebDavComicEntry comic) {
    if (comic.isDirectory && comic.isCategory) {
      // Category folder - navigate into it
      _navigateTo(comic.path, comic.name);
    } else {
      // Comic directory or archive file - open detail page
      context.to(() => WebDavComicDetailPage(comic: comic));
    }
  }
}

/// Card widget displaying a WebDAV comic thumbnail.
class _WebDavComicCard extends StatelessWidget {
  final WebDavComicEntry comic;
  final VoidCallback onTap;

  const _WebDavComicCard({required this.comic, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _buildCover(context),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s14.bold,
                  ),
                  if (comic.imageCount != null)
                    Text(
                      '${comic.imageCount} pages',
                      style: ts.s12.copyWith(
                        color: context.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    if (comic.coverPath != null) {
      return Image(
        image: WebDavImageProvider(comic.coverPath!),
        fit: BoxFit.cover,
        width: double.infinity,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        },
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[300],
      child: Center(
        child: Icon(
          comic.isCategory
              ? Icons.folder_open
              : (comic.isDirectory ? Icons.folder : Icons.archive),
          size: 48,
          color: comic.isCategory ? Colors.amber[700] : Colors.grey[600],
        ),
      ),
    );
  }
}

/// Detail page for a single WebDAV comic - shows chapters or images.
class WebDavComicDetailPage extends StatefulWidget {
  final WebDavComicEntry comic;

  const WebDavComicDetailPage({required this.comic});

  @override
  State<WebDavComicDetailPage> createState() => WebDavComicDetailPageState();
}

class WebDavComicDetailPageState extends State<WebDavComicDetailPage> {
  List<WebDavChapter>? _chapters;
  List<String>? _images;
  ComicInfo? _info;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WebDavProvider().addListener(_onUpdate);
    _loadComic();
  }

  @override
  void dispose() {
    WebDavProvider().removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadComic() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final provider = WebDavProvider();

      // Try to load info.json
      _info = await provider.loadComicInfo(widget.comic.path);

      if (widget.comic.isDirectory) {
        final chapters = await provider.getChapters(widget.comic.path);
        if (chapters.isNotEmpty) {
          setState(() {
            _chapters = chapters;
            _loading = false;
          });
        } else {
          final images = await provider.getComicImages(widget.comic.path);
          setState(() {
            _images = images;
            _loading = false;
          });
        }
      } else {
        final images = await provider.getComicImages(widget.comic.path);
        setState(() {
          _images = images;
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final displayTitle = info?.title ?? widget.comic.name;

    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text(displayTitle),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop(),
            ),
            actions: [
              _FavoriteButton(comic: widget.comic),
            ],
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, size: 48, color: Colors.red),
                    const SizedBox(height: 16),
                    Text(_error!),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _loadComic,
                      child: Text('Retry'.tl),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            // Cover
            if (widget.comic.coverPath != null)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 220,
                  child: Image(
                    image: WebDavImageProvider(widget.comic.coverPath!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image, size: 48),
                    ),
                  ),
                ),
              ),
            // Metadata section
            if (info != null && !info.isEmpty) _buildMetadata(info),
            // Content
            if (_chapters != null)
              _buildChapterList()
            else if (_images != null)
              _buildImageList()
            else
              SliverFillRemaining(
                child: Center(child: Text('No content found'.tl)),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetadata(ComicInfo info) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Author
            if (info.author != null && info.author!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  info.author!,
                  style: ts.s14.copyWith(
                    color: context.colorScheme.outline,
                  ),
                ),
              ),
            // Stars
            if (info.stars != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    ...List.generate(5, (i) {
                      return Icon(
                        i < info.stars!.floor()
                            ? Icons.star
                            : (i < info.stars!
                                ? Icons.star_half
                                : Icons.star_border),
                        color: Colors.amber,
                        size: 20,
                      );
                    }),
                    const SizedBox(width: 8),
                    Text(
                      info.stars!.toStringAsFixed(1),
                      style: ts.s14.bold,
                    ),
                  ],
                ),
              ),
            // Description
            if (info.description != null && info.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  info.description!,
                  style: ts.s14,
                ),
              ),
            // Tags
            if (info.tags.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var entry in info.tags.entries) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        entry.key,
                        style: ts.s12.bold.withColor(
                          context.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    for (var tag in entry.value)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: context.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(tag, style: ts.s12),
                      ),
                  ],
                ],
              ),
            const SizedBox(height: 8),
            const Divider(),
          ],
        ),
      ),
    );
  }

  History? get _history =>
      HistoryManager().find(widget.comic.path, ComicType.webdav);

  Widget _buildChapterList() {
    final history = _history;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      final ep = (history?.ep ?? 1).clamp(1, _chapters!.length);
                      _openChapter(_chapters![ep - 1], ep - 1,
                          initialPage: history != null && history.ep == ep
                              ? (history.page - 1).clamp(0, 99999)
                              : 0);
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      history != null && history.ep > 0
                          ? 'Continue'.tl
                          : 'Start Reading'.tl,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final chapter = _chapters![index];
              final isCurrent = history != null && history.ep == index + 1;
              final isArchive = chapter.path.endsWith('.cbz') ||
                  chapter.path.endsWith('.zip');

              return ListTile(
                selected: isCurrent,
                leading: CircleAvatar(
                  child: Text('${index + 1}'),
                ),
                title: Text(chapter.name),
                subtitle: Text(
                  chapter.imageCount > 0
                      ? '${chapter.imageCount} pages'
                      : (isArchive ? 'Stream'.tl : 'Online'.tl),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openChapter(chapter, index),
              );
            },
            childCount: _chapters!.length,
          ),
        ),
      ],
    );
  }

  Widget _buildImageList() {
    final history = _history;
    return SliverToBoxAdapter(
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            '${_images!.length} pages',
            style: ts.s16,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _startReading(
              _images!,
              history != null ? (history.page - 1).clamp(0, _images!.length - 1) : 0,
            ),
            icon: const Icon(Icons.play_arrow),
            label: Text(
              history != null && history.page > 1
                  ? 'Continue'.tl
                  : 'Start Reading'.tl,
            ),
          ),
          const SizedBox(height: 16),
          // Do not preload every page thumbnail for online comics
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Tap Start Reading to stream pages online.'.tl,
              style: ts.s12.copyWith(color: context.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _openChapter(WebDavChapter chapter, int chapterIndex,
      {int initialPage = 0}) async {
    // Stream-first: open reader immediately; images load on demand.
    if (mounted) {
      _startReading(const [], initialPage, chapterIndex: chapterIndex);
    }
  }

  /// Save a cover image to local cache for history / favorites display.
  Future<String> _saveCoverToLocal(String coverUrl) async {
    try {
      final provider = WebDavProvider();
      final data = await provider.loadImage(coverUrl);
      final pathHash = widget.comic.path.hashCode.toRadixString(16);
      final dir = Directory(
        FilePath.join(App.cachePath, 'webdav_covers'),
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = coverUrl.contains('.png') ? '.png' : '.jpg';
      final file = File(FilePath.join(dir.path, '$pathHash$ext'));
      await file.writeAsBytes(data);
      return 'file://${file.path}';
    } catch (e) {
      // Keep remote path so cover can still be loaded via WebDAV
      return coverUrl.startsWith('webdav://') || coverUrl.startsWith('file://')
          ? coverUrl
          : (coverUrl.isNotEmpty ? 'webdav://$coverUrl' : '');
    }
  }

  void _startReading(List<String> images, int initialPage,
      {int? chapterIndex}) async {
    // Chapter ids are remote paths so reader can stream without re-listing
    ComicChapters? chapters;
    if (_chapters != null && _chapters!.isNotEmpty) {
      final chapterMap = <String, String>{};
      for (final c in _chapters!) {
        chapterMap[c.path] = c.name;
      }
      chapters = ComicChapters(chapterMap);
    }

    final existing = HistoryManager().find(widget.comic.path, ComicType.webdav);
    final coverSource = widget.comic.coverPath ??
        (images.isNotEmpty ? images.first : existing?.cover ?? '');
    final coverLocal = coverSource.isNotEmpty
        ? (coverSource.startsWith('file://')
            ? coverSource
            : await _saveCoverToLocal(coverSource))
        : (existing?.cover ?? '');

    final ep = (chapterIndex ?? 0) + 1;
    final history = History.fromModel(
      model: _WebDavHistoryModel(
        title: widget.comic.name,
        cover: coverLocal,
        id: widget.comic.path,
        maxPage: images.isNotEmpty ? images.length : existing?.maxPage,
      ),
      ep: ep,
      page: initialPage + 1,
      time: DateTime.now(),
    );
    history.maxPage = images.isNotEmpty ? images.length : existing?.maxPage;
    // Persist immediately so history list works even if reader exits early
    HistoryManager().addHistory(history);

    if (!mounted) return;
    context.to(
      () => Reader(
        type: ComicType.webdav,
        cid: widget.comic.path,
        name: widget.comic.name,
        chapters: chapters,
        initialChapter: chapters != null ? ep : 1,
        initialPage: initialPage + 1,
        history: history,
        author: '',
        tags: const [],
      ),
    );
  }
}

/// Simple HistoryMixin implementation for WebDAV comics.
class _WebDavHistoryModel with HistoryMixin {
  @override
  final String title;

  @override
  final String cover;

  @override
  final String id;

  @override
  final int? maxPage;

  const _WebDavHistoryModel({
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

/// Favorite button for WebDAV comics.
class _FavoriteButton extends StatefulWidget {
  final WebDavComicEntry comic;
  const _FavoriteButton({required this.comic});

  @override
  State<_FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<_FavoriteButton> {
  bool _isFavorite = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _isFavorite = LocalFavoritesManager().isExist(
      widget.comic.path,
      ComicType.webdav,
    );
  }

  String _ensureFolder() {
    final manager = LocalFavoritesManager();
    final folders = manager.folderNames;
    if (folders.isNotEmpty) return folders.first;
    return manager.createFolder('default', true);
  }

  Future<String> _resolveCover() async {
    var cover = widget.comic.coverPath ?? '';
    if (cover.isEmpty) {
      try {
        await WebDavProvider().loadComics();
      } catch (_) {}
      cover = widget.comic.coverPath ?? '';
    }
    if (cover.isEmpty) return '';
    if (cover.startsWith('file://')) return cover;
    try {
      final data = await WebDavProvider().loadImage(cover);
      final pathHash = widget.comic.path.hashCode.toRadixString(16);
      final dir = Directory(FilePath.join(App.cachePath, 'webdav_covers'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = cover.contains('.png') ? '.png' : '.jpg';
      final file = File(FilePath.join(dir.path, 'fav_$pathHash$ext'));
      await file.writeAsBytes(data);
      return 'file://${file.path}';
    } catch (_) {
      return cover.startsWith('webdav://') ? cover : 'webdav://$cover';
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    _busy = true;
    try {
      final folder = _ensureFolder();
      if (_isFavorite) {
        // Remove from all folders that contain it
        for (final f in LocalFavoritesManager().folderNames) {
          if (LocalFavoritesManager().comicExists(f, widget.comic.path, ComicType.webdav)) {
            LocalFavoritesManager().deleteComicWithId(
              f,
              widget.comic.path,
              ComicType.webdav,
            );
          }
        }
        if (mounted) {
          setState(() => _isFavorite = false);
          context.showMessage(message: 'Removed from favorites'.tl);
        }
      } else {
        final cover = await _resolveCover();
        LocalFavoritesManager().addComic(
          folder,
          FavoriteItem(
            id: widget.comic.path,
            name: widget.comic.name,
            coverPath: cover,
            author: '',
            type: ComicType.webdav,
            tags: const [],
          ),
        );
        if (mounted) {
          setState(() => _isFavorite = true);
          context.showMessage(message: 'Added to favorites'.tl);
        }
      }
    } catch (e) {
      if (mounted) {
        context.showMessage(message: 'Failed: $e');
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(_isFavorite ? Icons.favorite : Icons.favorite_border),
      color: _isFavorite ? Colors.red : null,
      onPressed: _toggle,
      tooltip: _isFavorite ? 'Remove from favorites'.tl : 'Add to favorites'.tl,
    );
  }
}
