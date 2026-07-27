import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

/// A streaming ZIP reader that reads entries from a remote ZIP file
/// using HTTP Range requests, without downloading the entire file.
///
/// Flow:
/// 1. Follow 302 redirect to get CDN URL
/// 2. Read last 64KB to find End of Central Directory
/// 3. Read Central Directory to list all entries with sizes/offsets
/// 4. For each image: read local header → seek to data → read bytes
class StreamingZipReader {
  String? _cdnUrl;
  final String webdavUrl;
  final String user;
  final String pass;

  List<_ZipEntry>? _entries;
  int? _fileSize;

  StreamingZipReader({
    required this.webdavUrl,
    required this.user,
    required this.pass,
  });

  Future<String> _getCdnUrl() async {
    if (_cdnUrl != null) return _cdnUrl!;

    final dio = AppDio();
    final response = await dio.head(
      webdavUrl,
      options: Options(
        headers: {
          'authorization': 'Basic ${base64Encode(utf8.encode('$user:$pass'))}',
        },
      ),
    );

    final location = response.headers.value('location');
    if (location != null && location.startsWith('http')) {
      _cdnUrl = location;
    } else {
      _cdnUrl = webdavUrl;
    }
    return _cdnUrl!;
  }

  Future<Uint8List> _readRange(int start, int end) async {
    final url = await _getCdnUrl();
    final dio = AppDio(BaseOptions(
      method: 'GET',
      responseType: ResponseType.bytes,
    ));

    final response = await dio.get(
      url,
      options: Options(headers: {'Range': 'bytes=$start-$end'}),
    );

    if (response.data is List<int>) {
      return Uint8List.fromList(response.data as List<int>);
    }
    if (response.data is Uint8List) {
      return response.data as Uint8List;
    }
    throw Exception('Unexpected response type: ${response.data.runtimeType}');
  }

  Future<int> _getFileSize() async {
    if (_fileSize != null) return _fileSize!;
    final url = await _getCdnUrl();
    final dio = AppDio();
    final response = await dio.head(url);
    final cl = response.headers.value('content-length');
    if (cl == null) throw Exception('Cannot determine file size');
    _fileSize = int.parse(cl);
    return _fileSize!;
  }

  Future<void> _parseCentralDirectory() async {
    if (_entries != null) return;

    final fileSize = await _getFileSize();
    final tailSize = (fileSize < 65536) ? fileSize : 65536;
    final tailStart = fileSize - tailSize;
    final tail = await _readRange(tailStart, fileSize - 1);

    // Find EOCD (PK\x05\x06)
    int eocdPos = -1;
    for (int i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocdPos = i;
        break;
      }
    }
    if (eocdPos < 0) throw Exception('Invalid ZIP: EOCD not found');

    final eocd = ByteData.sublistView(tail, eocdPos);
    final entryCount = eocd.getUint16(10, Endian.little);
    final cdSize = eocd.getUint32(12, Endian.little);
    final cdOffset = eocd.getUint32(16, Endian.little);

    final cdData = await _readRange(cdOffset, cdOffset + cdSize - 1);

    _entries = [];
    int pos = 0;
    for (int i = 0; i < entryCount; i++) {
      if (pos + 46 > cdData.length) break;
      final sig = ByteData.sublistView(cdData).getUint32(pos, Endian.little);
      if (sig != 0x02014B50) break;

      final method = ByteData.sublistView(cdData).getUint16(pos + 10, Endian.little);
      final compSize = ByteData.sublistView(cdData).getUint32(pos + 20, Endian.little);
      final uncompSize = ByteData.sublistView(cdData).getUint32(pos + 24, Endian.little);
      final fnameLen = ByteData.sublistView(cdData).getUint16(pos + 28, Endian.little);
      final extraLen = ByteData.sublistView(cdData).getUint16(pos + 30, Endian.little);
      final commentLen = ByteData.sublistView(cdData).getUint16(pos + 32, Endian.little);
      final localOffset = ByteData.sublistView(cdData).getUint32(pos + 42, Endian.little);

      final fname = utf8.decode(
        cdData.sublist(pos + 46, pos + 46 + fnameLen),
        allowMalformed: true,
      );

      _entries!.add(_ZipEntry(
        fileName: fname,
        compressedSize: compSize,
        uncompressedSize: uncompSize,
        compressionMethod: method,
        localHeaderOffset: localOffset,
      ));

      pos += 46 + fnameLen + extraLen + commentLen;
    }

    Log.info("StreamingZip", "Parsed ${_entries!.length} entries");
  }

  Future<List<ZipEntryInfo>> listEntries() async {
    await _parseCentralDirectory();
    return _entries!
        .map((e) => ZipEntryInfo(
              fileName: e.fileName,
              compressedSize: e.compressedSize,
              uncompressedSize: e.uncompressedSize,
              isDirectory: e.fileName.endsWith('/'),
            ))
        .toList();
  }

  /// Read a single entry from the ZIP by its filename.
  Future<Uint8List> readEntry(String fileName) async {
    await _parseCentralDirectory();
    final entry = _entries!.firstWhere(
      (e) => e.fileName == fileName,
      orElse: () => throw Exception('Entry not found: $fileName'),
    );

    // Read local file header to find data offset
    final headerEnd = entry.localHeaderOffset + 30 + 256; // 30 + max fname+extra
    final headerData = await _readRange(
      entry.localHeaderOffset,
      headerEnd > (await _getFileSize()) ? (await _getFileSize()) - 1 : headerEnd,
    );

    final lh = ByteData.sublistView(headerData);
    final lhSig = lh.getUint32(0, Endian.little);
    if (lhSig != 0x04034B50) {
      throw Exception('Invalid local header at ${entry.localHeaderOffset}');
    }

    final lhFnameLen = lh.getUint16(26, Endian.little);
    final lhExtraLen = lh.getUint16(28, Endian.little);
    final dataOffset = entry.localHeaderOffset + 30 + lhFnameLen + lhExtraLen;

    // Read compressed data using size from central directory
    if (entry.compressedSize == 0) {
      throw Exception('Entry has zero compressed size: $fileName');
    }

    final data = await _readRange(
      dataOffset,
      dataOffset + entry.compressedSize - 1,
    );

    if (entry.compressionMethod == 0) {
      // Stored (no compression) - most CBZ files use this
      return data;
    } else if (entry.compressionMethod == 8) {
      // Deflate - need to decompress
      return _inflateRaw(data);
    } else {
      throw Exception('Unsupported compression: ${entry.compressionMethod}');
    }
  }

  Uint8List _inflateRaw(Uint8List compressed) {
    // ZIP method 8 is raw deflate (no zlib wrapper).
    try {
      return Uint8List.fromList(
        const ZLibCodec(raw: true).decode(compressed),
      );
    } catch (_) {
      return Uint8List.fromList(zlib.decode(compressed));
    }
  }

  void dispose() {
    _cdnUrl = null;
    _entries = null;
    _fileSize = null;
  }
}

class _ZipEntry {
  final String fileName;
  final int compressedSize;
  final int uncompressedSize;
  final int compressionMethod;
  final int localHeaderOffset;

  const _ZipEntry({
    required this.fileName,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.compressionMethod,
    required this.localHeaderOffset,
  });
}

class ZipEntryInfo {
  final String fileName;
  final int compressedSize;
  final int uncompressedSize;
  final bool isDirectory;

  const ZipEntryInfo({
    required this.fileName,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.isDirectory,
  });
}
