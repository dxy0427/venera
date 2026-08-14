import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'natural_sort.dart';

/// A local CBZ/ZIP image reference. The archive remains on disk and the image
/// is decoded only when the reader requests it.
class LocalCbzResourceRef {
  final String archivePath;
  final String entryName;

  const LocalCbzResourceRef({
    required this.archivePath,
    required this.entryName,
  });

  String encode() {
    return Uri(
      scheme: 'localcbz',
      host: 'resource',
      path: '/v1',
      queryParameters: {'path': archivePath, 'entry': entryName},
    ).toString();
  }

  static LocalCbzResourceRef parse(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'localcbz' ||
        uri.host != 'resource' ||
        uri.path != '/v1') {
      throw const FormatException('Invalid local CBZ resource reference');
    }
    final archivePath = uri.queryParameters['path'];
    final entryName = uri.queryParameters['entry'];
    if (archivePath == null ||
        archivePath.isEmpty ||
        entryName == null ||
        entryName.isEmpty) {
      throw const FormatException('Invalid local CBZ resource reference');
    }
    return LocalCbzResourceRef(archivePath: archivePath, entryName: entryName);
  }

  static bool isReference(String value) {
    try {
      parse(value);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class LocalCbzEntry {
  final String fileName;
  final int flags;
  final int compressedSize;
  final int uncompressedSize;
  final int compressionMethod;
  final int localHeaderOffset;
  final bool isDirectory;

  const LocalCbzEntry({
    required this.fileName,
    required this.flags,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.compressionMethod,
    required this.localHeaderOffset,
    required this.isDirectory,
  });
}

/// Pure Dart random-access reader for regular ZIP/CBZ files.
///
/// It reads the central directory and only the requested entry, so importing a
/// CBZ chapter does not require extracting the archive to a directory.
abstract final class LocalCbzReader {
  static const _coverBaseNames = {'cover', 'folder', 'thumb', '封面'};
  static const _maxCachedIndexes = 64;
  static const _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'jpe',
    'bmp',
    'tiff',
    'tif',
    'avif',
  };

  static final Map<String, _ArchiveIndex> _indexes = {};
  static final Map<String, Future<_ArchiveIndex>> _indexRequests = {};

  static Future<List<LocalCbzEntry>> listEntries(String archivePath) async {
    final file = File(archivePath);
    if (!await file.exists()) {
      throw StateError('CBZ archive not found: $archivePath');
    }
    final size = await file.length();
    final cached = _indexes[archivePath];
    if (cached != null && cached.size == size) {
      return cached.entries;
    }
    final pending = _indexRequests[archivePath];
    if (pending != null) return (await pending).entries;

    final request = _parseIndex(file, size);
    _indexRequests[archivePath] = request;
    try {
      final index = await request;
      _indexes.remove(archivePath);
      _indexes[archivePath] = index;
      while (_indexes.length > _maxCachedIndexes) {
        _indexes.remove(_indexes.keys.first);
      }
      return index.entries;
    } finally {
      if (identical(_indexRequests[archivePath], request)) {
        _indexRequests.remove(archivePath);
      }
    }
  }

  static Future<_ArchiveIndex> _parseIndex(File file, int size) async {
    final handle = await file.open();
    try {
      final tailSize = size < 65557 ? size : 65557;
      final tailStart = size - tailSize;
      final tail = await _readAt(handle, tailStart, tailSize);
      final eocd = _findEocd(tail);
      if (eocd < 0 || eocd + 22 > tail.length) {
        throw const FormatException('Invalid ZIP: EOCD not found');
      }

      final data = ByteData.sublistView(tail, eocd);
      final diskNumber = data.getUint16(4, Endian.little);
      final centralDisk = data.getUint16(6, Endian.little);
      final diskEntryCount = data.getUint16(8, Endian.little);
      final entryCount = data.getUint16(10, Endian.little);
      final centralSize = data.getUint32(12, Endian.little);
      final centralOffset = data.getUint32(16, Endian.little);
      if (diskNumber != 0 || centralDisk != 0 || diskEntryCount != entryCount) {
        throw const FormatException('Multi-disk ZIP is not supported');
      }
      if (entryCount == 0xFFFF ||
          centralSize == 0xFFFFFFFF ||
          centralOffset == 0xFFFFFFFF) {
        throw const FormatException('ZIP64 is not supported for local CBZ');
      }
      if (centralOffset + centralSize > size) {
        throw const FormatException('Invalid ZIP central directory');
      }

      final central = await _readAt(handle, centralOffset, centralSize);
      final entries = <LocalCbzEntry>[];
      var position = 0;
      for (var i = 0; i < entryCount; i++) {
        if (position + 46 > central.length) {
          throw const FormatException('Invalid ZIP central directory');
        }
        final header = ByteData.sublistView(central, position);
        if (header.getUint32(0, Endian.little) != 0x02014B50) {
          throw const FormatException('Invalid ZIP central directory entry');
        }
        final compressionMethod = header.getUint16(10, Endian.little);
        final flags = header.getUint16(8, Endian.little);
        final compressedSize = header.getUint32(20, Endian.little);
        final uncompressedSize = header.getUint32(24, Endian.little);
        final fileNameLength = header.getUint16(28, Endian.little);
        final extraLength = header.getUint16(30, Endian.little);
        final commentLength = header.getUint16(32, Endian.little);
        final localHeaderOffset = header.getUint32(42, Endian.little);
        final nameStart = position + 46;
        final nameEnd = nameStart + fileNameLength;
        if (nameEnd + extraLength + commentLength > central.length) {
          throw const FormatException('Invalid ZIP central directory entry');
        }
        final fileName = utf8.decode(
          central.sublist(nameStart, nameEnd),
          allowMalformed: true,
        );
        entries.add(
          LocalCbzEntry(
            fileName: fileName,
            flags: flags,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            compressionMethod: compressionMethod,
            localHeaderOffset: localHeaderOffset,
            isDirectory: fileName.endsWith('/'),
          ),
        );
        position += 46 + fileNameLength + extraLength + commentLength;
      }
      return _ArchiveIndex(size: size, entries: List.unmodifiable(entries));
    } finally {
      await handle.close();
    }
  }

  static Future<List<LocalCbzEntry>> listImages(String archivePath) async {
    final entries = await listEntries(archivePath);
    final names = <String>{};
    final images = entries.where((entry) {
      if (entry.isDirectory) return false;
      final dot = entry.fileName.lastIndexOf('.');
      if (dot < 0) return false;
      final isImage = _imageExtensions.contains(
        entry.fileName.substring(dot + 1).toLowerCase(),
      );
      if (!isImage) return false;
      if ((entry.flags & 0x1) != 0) {
        throw UnsupportedError('Encrypted ZIP entries are not supported');
      }
      if (entry.compressionMethod != 0 && entry.compressionMethod != 8) {
        throw UnsupportedError(
          'Unsupported ZIP compression: ${entry.compressionMethod}',
        );
      }
      if (!names.add(entry.fileName)) {
        throw FormatException('Duplicate ZIP entry: ${entry.fileName}');
      }
      return true;
    }).toList();
    images.sort((a, b) => naturalComparePath(a.fileName, b.fileName));
    return images;
  }

  static Future<List<String>> listImageReferences(String archivePath) async {
    final allImages = await listImages(archivePath);
    final pages = allImages.where((entry) => !_isCoverEntry(entry)).toList();
    final entries = pages.isEmpty ? allImages : pages;
    return entries
        .map(
          (entry) => LocalCbzResourceRef(
            archivePath: archivePath,
            entryName: entry.fileName,
          ).encode(),
        )
        .toList();
  }

  static bool _isCoverEntry(LocalCbzEntry entry) {
    final leaf = entry.fileName.replaceAll('\\', '/').split('/').last;
    final dot = leaf.lastIndexOf('.');
    final base = (dot > 0 ? leaf.substring(0, dot) : leaf).toLowerCase();
    return _coverBaseNames.contains(base);
  }

  static Future<Uint8List> readReference(String reference) async {
    final ref = LocalCbzResourceRef.parse(reference);
    return readEntry(ref.archivePath, ref.entryName);
  }

  static Future<Uint8List> readEntry(
    String archivePath,
    String entryName,
  ) async {
    final entries = await listEntries(archivePath);
    final entry = entries.firstWhere(
      (value) => value.fileName == entryName,
      orElse: () => throw StateError('Entry not found: $entryName'),
    );
    if (entry.isDirectory) throw StateError('Entry is a directory: $entryName');

    final file = File(archivePath);
    final handle = await file.open();
    try {
      final localHeader = await _readAt(handle, entry.localHeaderOffset, 30);
      final header = ByteData.sublistView(localHeader);
      if (header.getUint32(0, Endian.little) != 0x04034B50) {
        throw const FormatException('Invalid ZIP local header');
      }
      final fileNameLength = header.getUint16(26, Endian.little);
      final extraLength = header.getUint16(28, Endian.little);
      final dataOffset =
          entry.localHeaderOffset + 30 + fileNameLength + extraLength;
      final compressed = await _readAt(
        handle,
        dataOffset,
        entry.compressedSize,
      );
      late Uint8List result;
      switch (entry.compressionMethod) {
        case 0:
          result = compressed;
        case 8:
          try {
            result = Uint8List.fromList(
              ZLibCodec(raw: true).decode(compressed),
            );
          } catch (_) {
            result = Uint8List.fromList(zlib.decode(compressed));
          }
        default:
          throw UnsupportedError(
            'Unsupported ZIP compression: ${entry.compressionMethod}',
          );
      }
      if (result.length != entry.uncompressedSize) {
        throw const FormatException('Invalid ZIP entry size');
      }
      return result;
    } finally {
      await handle.close();
    }
  }

  static int _findEocd(Uint8List data) {
    for (var i = data.length - 22; i >= 0; i--) {
      final view = ByteData.sublistView(data, i);
      if (view.getUint32(0, Endian.little) != 0x06054B50) continue;
      final commentLength = view.getUint16(20, Endian.little);
      if (i + 22 + commentLength == data.length) return i;
    }
    return -1;
  }

  static Future<Uint8List> _readAt(
    RandomAccessFile file,
    int offset,
    int length,
  ) async {
    if (length == 0) return Uint8List(0);
    await file.setPosition(offset);
    final result = Uint8List(length);
    var position = 0;
    while (position < length) {
      final count = await file.readInto(result, position, length);
      if (count == 0) {
        throw const FormatException('Unexpected end of ZIP file');
      }
      position += count;
    }
    return result;
  }
}

class _ArchiveIndex {
  final int size;
  final List<LocalCbzEntry> entries;

  const _ArchiveIndex({required this.size, required this.entries});
}
