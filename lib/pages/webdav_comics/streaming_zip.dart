import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

/// Streaming ZIP reader via HTTP Range requests (no full-file download).
///
/// OpenList / AList / 123pan style WebDAV often answers file GET with 302 to a
/// signed CDN URL. Auth is only sent to the original WebDAV origin; cross-host
/// hops never receive Basic Auth.
class StreamingZipReader {
  String? _cdnUrl;
  final String webdavUrl;
  final String user;
  final String pass;

  /// Optional size from WebDAV PROPFIND (avoids another HEAD round-trip).
  final int? knownFileSize;

  List<_ZipEntry>? _entries;
  int? _fileSize;
  final Uri _origin;

  StreamingZipReader({
    required this.webdavUrl,
    required this.user,
    required this.pass,
    this.knownFileSize,
  }) : _origin = Uri.parse(webdavUrl) {
    if (knownFileSize != null && knownFileSize! > 0) {
      _fileSize = knownFileSize;
    }
  }

  Map<String, String> get _authHeaders => {
    'authorization': 'Basic ${base64Encode(utf8.encode('$user:$pass'))}',
  };

  bool _isRedirect(int? s) =>
      s == 301 || s == 302 || s == 303 || s == 307 || s == 308;

  bool _isSuccess(int? s) => s != null && s >= 200 && s < 300;

  int _effectivePort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme == 'https' ? 443 : 80;
  }

  bool _sameOrigin(String url) {
    final u = Uri.parse(url);
    return u.scheme == _origin.scheme &&
        u.host == _origin.host &&
        _effectivePort(u) == _effectivePort(_origin);
  }

  String? _absoluteLocation(Response response, String baseUrl) {
    final raw = response.headers.value('location');
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    return Uri.parse(baseUrl).resolve(raw).toString();
  }

  void _captureSize(Response response) {
    final cr = response.headers.value('content-range');
    final m = RegExp(r'/(\d+)\s*$').firstMatch(cr ?? '');
    if (m != null) {
      _fileSize = int.tryParse(m.group(1)!);
      return;
    }
    final cl = response.headers.value('content-length');
    if (cl != null) _fileSize ??= int.tryParse(cl);
  }

  Map<String, dynamic> _headersFor(String url, {Map<String, String>? extra}) {
    return <String, dynamic>{
      if (_sameOrigin(url)) ..._authHeaders,
      if (extra != null) ...extra,
    };
  }

  /// Follow redirects manually. Auth only on the original WebDAV origin.
  Future<Response> _request(
    String method,
    String startUrl, {
    Map<String, String>? extraHeaders,
    ResponseType responseType = ResponseType.bytes,
    int maxHops = 8,
  }) async {
    var url = startUrl;
    final dio = AppDio(
      BaseOptions(
        followRedirects: false,
        validateStatus: (s) => s != null && (s < 400 || _isRedirect(s)),
      ),
    );

    for (var hop = 0; hop < maxHops; hop++) {
      final headers = _headersFor(url, extra: extraHeaders);
      final response = method == 'HEAD'
          ? await dio.head(url, options: Options(headers: headers))
          : await dio.get(
              url,
              options: Options(headers: headers, responseType: responseType),
            );

      if (_isRedirect(response.statusCode)) {
        final next = _absoluteLocation(response, url);
        if (next == null || next.isEmpty) {
          throw Exception(
            'Redirect without Location from ${Uri.parse(url).host}',
          );
        }
        // Never treat a redirect response as final download URL content.
        url = next;
        continue;
      }

      if (_isSuccess(response.statusCode)) {
        _captureSize(response);
        // Cache final resolved URL for subsequent ranges.
        if (method != 'HEAD' || !_sameOrigin(url)) {
          _cdnUrl = url;
        }
        return response;
      }

      throw Exception(
        '$method ${Uri.parse(url).host} failed with status '
        '${response.statusCode}',
      );
    }
    throw Exception('Too many redirects');
  }

  Future<Uint8List> _readRange(int start, int end) async {
    // Start from resolved CDN if known; otherwise from WebDAV so redirects
    // are followed manually without leaking Auth to foreign hosts.
    final startUrl = _cdnUrl ?? webdavUrl;
    Response response;
    try {
      response = await _request(
        'GET',
        startUrl,
        extraHeaders: {'Range': 'bytes=$start-$end'},
        responseType: ResponseType.bytes,
      );
    } catch (e) {
      if (startUrl == webdavUrl) rethrow;
      // Signed CDN URLs can expire during a long reading session.
      _cdnUrl = null;
      response = await _request(
        'GET',
        webdavUrl,
        extraHeaders: {'Range': 'bytes=$start-$end'},
        responseType: ResponseType.bytes,
      );
    }

    if (response.data is Uint8List) {
      return response.data as Uint8List;
    }
    if (response.data is List<int>) {
      return Uint8List.fromList(response.data as List<int>);
    }
    throw Exception('Unexpected response type: ${response.data.runtimeType}');
  }

  Future<int> _getFileSize() async {
    if (_fileSize != null) return _fileSize!;

    try {
      await _request('HEAD', webdavUrl);
      if (_fileSize != null) return _fileSize!;
    } catch (e) {
      // Some CDNs reject HEAD (e.g. 403) but allow ranged GETs; the
      // bytes=0-0 fallback below is authoritative.
      Log.info("StreamingZip", "size HEAD failed; falling back to ranged GET");
    }

    await _request(
      'GET',
      webdavUrl,
      extraHeaders: const {'Range': 'bytes=0-0'},
      responseType: ResponseType.bytes,
    );
    if (_fileSize != null) return _fileSize!;
    throw Exception('Cannot determine file size');
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

    // ZIP64 / truncated central directory guard
    if (cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      throw Exception('ZIP64 not supported for streaming');
    }

    final cdData = await _readRange(cdOffset, cdOffset + cdSize - 1);

    _entries = [];
    int pos = 0;
    for (int i = 0; i < entryCount; i++) {
      if (pos + 46 > cdData.length) break;
      final sig = ByteData.sublistView(cdData).getUint32(pos, Endian.little);
      if (sig != 0x02014B50) break;

      final method = ByteData.sublistView(
        cdData,
      ).getUint16(pos + 10, Endian.little);
      final compSize = ByteData.sublistView(
        cdData,
      ).getUint32(pos + 20, Endian.little);
      final uncompSize = ByteData.sublistView(
        cdData,
      ).getUint32(pos + 24, Endian.little);
      final fnameLen = ByteData.sublistView(
        cdData,
      ).getUint16(pos + 28, Endian.little);
      final extraLen = ByteData.sublistView(
        cdData,
      ).getUint16(pos + 30, Endian.little);
      final commentLen = ByteData.sublistView(
        cdData,
      ).getUint16(pos + 32, Endian.little);
      final localOffset = ByteData.sublistView(
        cdData,
      ).getUint32(pos + 42, Endian.little);

      final fname = utf8.decode(
        cdData.sublist(pos + 46, pos + 46 + fnameLen),
        allowMalformed: true,
      );

      _entries!.add(
        _ZipEntry(
          fileName: fname,
          compressedSize: compSize,
          uncompressedSize: uncompSize,
          compressionMethod: method,
          localHeaderOffset: localOffset,
        ),
      );

      pos += 46 + fnameLen + extraLen + commentLen;
    }

    Log.info(
      "StreamingZip",
      "Parsed ${_entries!.length} entries from $webdavUrl",
    );
  }

  Future<List<ZipEntryInfo>> listEntries() async {
    await _parseCentralDirectory();
    return _entries!
        .map(
          (e) => ZipEntryInfo(
            fileName: e.fileName,
            compressedSize: e.compressedSize,
            uncompressedSize: e.uncompressedSize,
            isDirectory: e.fileName.endsWith('/'),
          ),
        )
        .toList();
  }

  Future<Uint8List> readEntry(String fileName) async {
    await _parseCentralDirectory();
    final entry = _entries!.firstWhere(
      (e) => e.fileName == fileName,
      orElse: () => throw Exception('Entry not found: $fileName'),
    );

    final fileSize = await _getFileSize();
    final headerEnd = entry.localHeaderOffset + 30 + 1024;
    final headerData = await _readRange(
      entry.localHeaderOffset,
      headerEnd >= fileSize ? fileSize - 1 : headerEnd,
    );

    final lh = ByteData.sublistView(headerData);
    final lhSig = lh.getUint32(0, Endian.little);
    if (lhSig != 0x04034B50) {
      throw Exception('Invalid local header at ${entry.localHeaderOffset}');
    }

    final lhFnameLen = lh.getUint16(26, Endian.little);
    final lhExtraLen = lh.getUint16(28, Endian.little);
    final dataOffset = entry.localHeaderOffset + 30 + lhFnameLen + lhExtraLen;

    if (entry.compressedSize == 0) {
      throw Exception('Entry has zero compressed size: $fileName');
    }

    final data = await _readRange(
      dataOffset,
      dataOffset + entry.compressedSize - 1,
    );

    if (entry.compressionMethod == 0) {
      return data;
    } else if (entry.compressionMethod == 8) {
      return _inflateRaw(data);
    } else {
      throw Exception('Unsupported compression: ${entry.compressionMethod}');
    }
  }

  Uint8List _inflateRaw(Uint8List compressed) {
    try {
      return Uint8List.fromList(ZLibCodec(raw: true).decode(compressed));
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
