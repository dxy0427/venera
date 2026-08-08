# Import Comic

## Introduction

Venera supports importing comics from local files.
However, the comic files must be in a specific format.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Local` -> `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in Settings points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory is considered a comic directory when it follows one of the
structures below.

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a valid image extension.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

**With Archive Chapters**

```
comic_directory
├── cover.[ext]       (optional)
├── info.json         (optional)
├── chapter1.cbz
├── chapter2.cbz
├── final.cbz
└── afterword.cbz
```

Choose `Import Comics` -> `Archive chapter directory`. Each archive is imported
as one chapter. Archive extensions are removed from chapter names, and nested
image folders inside an archive are read in path-aware natural order. CBZ/ZIP
files are copied into the app local path and read directly without extraction.
If no cover is provided, the first image from the first chapter becomes
`cover.[ext]`. Do not put chapter directories in an archive chapter directory.
Direct chapter reading currently supports regular `.cbz` and `.zip` files
using Store or Deflate compression. Encrypted, ZIP64, multi-disk, and other
compression formats are not supported; use the existing archive import for
`.7z` / `.cb7` files.

Optional `info.json` example:

```json
{
  "title": "漫画名",
  "author": "作者",
  "description": "简介",
  "tags": {
    "题材": ["题材1", "题材2"],
    "状态": ["连载中"],
    "年份": ["2025"],
    "语言": ["中文"]
  },
  "cover": "cover.jpg",
  "stars": 8.7
}
```

Present fields only. The detail page displays rating, then the top-level
`author`, then `tags` in the same order as the JSON file, followed by the
automatic or manually supplied update time. Tag names are not restricted:
`题材`, `地区`, `热度`, `状态` and other custom names are all allowed.

## Archive

Venera supports importing comics from archive files.

The archive file must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, Venera supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`
