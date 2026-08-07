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

A directory considered as a comic directory only if it follows one of the following two types of structure:

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
├── cover.[ext]
├── info.json
├── chapter1.cbz
├── chapter2.cbz
├── final.cbz
└── afterword.cbz
```

Each archive is imported as one chapter. Archive extensions are removed from
chapter names, and nested image folders inside an archive are flattened in
path-aware natural order. This format must be copied to the app local path so
the chapter archives can be extracted. Do not mix chapter directories and
chapter archives in the same comic directory.

Optional `info.json` fields:

```json
{
  "title": "Comic title",
  "author": "Author A, Author B",
  "description": "Description",
  "cover": "cover.jpg",
  "stars": 4.5,
  "updateTime": "2026-08-07",
  "tags": {
    "Genre": ["Drama"],
    "Year": ["2026"],
    "Language": ["Chinese"]
  }
}
```

Local and WebDAV detail pages display only Author, Genre, Year and Language
from metadata tags. Subtitle and Artist namespaces are ignored.

## Archive

Venera supports importing comics from archive files.

The archive file must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, Venera supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`
