import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'webdav_image_provider.dart';
import 'webdav_models.dart';
import 'webdav_provider.dart';
import 'webdav_settings_page.dart';
import 'webdav_references.dart';

/// Sort mode for WebDAV comics.
enum WebDavSortMode {
  titleAsc('title_asc', 'Title ↑'),
  titleDesc('title_desc', 'Title ↓'),
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
  final String accountId;
  final String? displayName;

  const WebDavComicsPage({
    super.key,
    required this.accountId,
    this.displayName,
  });

  @override
  State<WebDavComicsPage> createState() => _WebDavComicsPageState();
}

class _WebDavComicsPageState extends State<WebDavComicsPage> {
  late final WebDavProvider _provider;
  WebDavSortMode _sortMode = WebDavSortMode.titleAsc;

  /// Display titles from info.json (path -> title).
  final Map<String, String> _infoTitles = {};
  String? _infoAccountId;

  /// Current browsing path (null = root).
  String? _currentPath;

  /// Breadcrumb path segments.
  final List<_PathSegment> _breadcrumbs = [];
  @override
  void initState() {
    super.initState();
    _infoAccountId = widget.accountId;
    _provider = WebDavProvider.forAccount(widget.accountId);
    _provider.addListener(_onUpdate);
    if (_provider.comics == null && !_provider.isLoading) {
      _provider.loadComics();
    }
  }

  void _navigateTo(String path, String name) {
    setState(() {
      _breadcrumbs.add(_PathSegment(name: name, path: _currentPath ?? ''));
      _currentPath = path;
    });
    _provider.loadDirectory(path);
  }

  void _navigateBack() {
    if (_breadcrumbs.isNotEmpty) {
      final prev = _breadcrumbs.removeLast();
      setState(() {
        _currentPath = prev.path.isEmpty ? null : prev.path;
      });
      if (_currentPath == null) {
        _provider.loadComics(forceRefresh: true);
      } else {
        _provider.loadDirectory(_currentPath!);
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
    _provider.loadComics(forceRefresh: true);
  }

  @override
  void dispose() {
    _provider.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    final accountId = widget.accountId;
    if (accountId != _infoAccountId) {
      _infoAccountId = accountId;
      _infoTitles.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;

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
                : Text(widget.displayName ?? 'WebDAV Comics'.tl),
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
                    _provider.loadDirectory(_currentPath!);
                  } else {
                    _provider.refresh();
                  }
                },
                tooltip: 'Refresh'.tl,
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => context.to(() => const WebDavSettingsPage()),
                tooltip: 'Settings'.tl,
              ),
            ],
          ),
          if (provider.isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (provider.error != null)
            SliverFillRemaining(child: _buildError(provider.error!))
          else if (_currentComics.isEmpty)
            SliverFillRemaining(child: _buildEmpty())
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
            onPressed: () => _provider.refresh(),
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
                    // ignore: deprecated_member_use
                    groupValue: _sortMode,
                    // ignore: deprecated_member_use
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

  String _titleKey(String path) => '${_infoAccountId ?? 'default'}@$path';

  String _displayTitle(WebDavComicEntry c) =>
      _infoTitles[_titleKey(c.path)] ?? c.name;

  Future<void> _loadInfoTitles(List<WebDavComicEntry> comics) async {
    var changed = false;
    final pending = comics.where(
      (c) =>
          c.isDirectory &&
          !c.isCategory &&
          !_infoTitles.containsKey(_titleKey(c.path)),
    );
    const batchSize = 6;
    final list = pending.toList();
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      await Future.wait(
        batch.map((c) async {
          try {
            final info = await _provider.loadComicInfo(
              WebDavResourceRef.comic(widget.accountId, c.path).encode(),
            );
            final t = info?.title?.trim();
            _infoTitles[_titleKey(c.path)] = (t != null && t.isNotEmpty)
                ? t
                : c.name;
            changed = true;
          } catch (_) {
            _infoTitles[_titleKey(c.path)] = c.name;
          }
        }),
      );
    }
    if (changed && mounted) {
      setState(() {});
    }
  }

  List<WebDavComicEntry> _sortComics(List<WebDavComicEntry> comics) {
    final sorted = List<WebDavComicEntry>.from(comics);
    // Prefetch info.json titles for title sort / display
    Future.microtask(() => _loadInfoTitles(comics));
    // Category folders always come first
    sorted.sort((a, b) {
      if (a.isCategory && !b.isCategory) return -1;
      if (!a.isCategory && b.isCategory) return 1;
      switch (_sortMode) {
        case WebDavSortMode.titleAsc:
          return _displayTitle(
            a,
          ).toLowerCase().compareTo(_displayTitle(b).toLowerCase());
        case WebDavSortMode.titleDesc:
          return _displayTitle(
            b,
          ).toLowerCase().compareTo(_displayTitle(a).toLowerCase());
        case WebDavSortMode.nameAsc:
          return a.name.compareTo(b.name);
        case WebDavSortMode.nameDesc:
          return b.name.compareTo(a.name);
        case WebDavSortMode.dateAsc:
          return (a.modified ?? DateTime(2000)).compareTo(
            b.modified ?? DateTime(2000),
          );
        case WebDavSortMode.dateDesc:
          return (b.modified ?? DateTime(2000)).compareTo(
            a.modified ?? DateTime(2000),
          );
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
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index >= sorted.length) return null;
        return _WebDavComicCard(
          comic: sorted[index],
          title: _displayTitle(sorted[index]),
          accountId: widget.accountId,
          onTap: () => _openComic(sorted[index]),
        );
      }, childCount: sorted.length),
    );
  }

  List<WebDavComicEntry> get _currentComics {
    return _provider.directoryEntries ?? _provider.comics ?? [];
  }

  void _openComic(WebDavComicEntry comic) {
    if (comic.isDirectory && comic.isCategory) {
      // Category folder - navigate into it
      _navigateTo(comic.path, comic.name);
    } else {
      // Open standard ComicPage (same UI as network sources)
      final raw = comic.coverPath;
      final cover = raw == null || raw.isEmpty
          ? (!comic.isDirectory
                ? WebDavResourceRef.stream(
                    widget.accountId,
                    comic.path,
                  ).encode()
                : null)
          : (raw.startsWith('stream://')
                ? WebDavResourceRef.stream(
                    widget.accountId,
                    raw.substring(9),
                  ).encode()
                : WebDavResourceRef.image(widget.accountId, raw).encode());
      context.to(
        () => ComicPage(
          id: WebDavResourceRef.comic(widget.accountId, comic.path).encode(),
          sourceKey: 'webdav',
          title: _displayTitle(comic),
          cover: cover,
        ),
      );
    }
  }
}

/// Card widget displaying a WebDAV comic thumbnail.
class _WebDavComicCard extends StatelessWidget {
  final WebDavComicEntry comic;
  final String title;
  final String accountId;
  final VoidCallback onTap;

  const _WebDavComicCard({
    required this.comic,
    required this.title,
    required this.accountId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildCover(context)),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
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
        image: WebDavImageProvider(
          comic.coverPath!.startsWith('stream://')
              ? WebDavResourceRef.stream(
                  accountId,
                  comic.coverPath!.substring(9),
                ).encode()
              : WebDavResourceRef.image(accountId, comic.coverPath!).encode(),
        ),
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
