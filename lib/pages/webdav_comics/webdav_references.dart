/// The kind of a resource stored on a WebDAV comic source.
enum WebDavResourceKind { comic, chapter, image, streamImage }

/// Immutable, account-scoped reference to a WebDAV resource.
///
/// References are encoded as URI query parameters instead of concatenated
/// paths, so account IDs and remote paths may contain any URL-safe text.
class WebDavResourceRef {
  final String accountId;
  final String remotePath;
  final WebDavResourceKind kind;
  final String? entryName;

  const WebDavResourceRef({
    required this.accountId,
    required this.remotePath,
    required this.kind,
    this.entryName,
  });

  factory WebDavResourceRef.comic(String accountId, String remotePath) =>
      WebDavResourceRef(
        accountId: accountId,
        remotePath: remotePath,
        kind: WebDavResourceKind.comic,
      );

  factory WebDavResourceRef.chapter(String accountId, String remotePath) =>
      WebDavResourceRef(
        accountId: accountId,
        remotePath: remotePath,
        kind: WebDavResourceKind.chapter,
      );

  factory WebDavResourceRef.image(String accountId, String remotePath) =>
      WebDavResourceRef(
        accountId: accountId,
        remotePath: remotePath,
        kind: WebDavResourceKind.image,
      );

  factory WebDavResourceRef.stream(
    String accountId,
    String remotePath, [
    String? entryName,
  ]) => WebDavResourceRef(
    accountId: accountId,
    remotePath: remotePath,
    kind: WebDavResourceKind.streamImage,
    entryName: entryName,
  );

  bool get isStream => kind == WebDavResourceKind.streamImage;

  String encode() {
    return Uri(
      scheme: 'webdav',
      host: 'resource',
      path: '/v1',
      queryParameters: {
        'accountId': accountId,
        'path': remotePath,
        'kind': kind.name,
        if (entryName != null) 'entry': entryName!,
      },
    ).toString();
  }

  static WebDavResourceRef parse(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'webdav' || uri.host != 'resource' || uri.path != '/v1') {
      throw const FormatException('Invalid WebDAV resource reference');
    }
    final accountId = uri.queryParameters['accountId'];
    final remotePath = uri.queryParameters['path'];
    final kindName = uri.queryParameters['kind'];
    if (accountId == null ||
        accountId.isEmpty ||
        remotePath == null ||
        remotePath.isEmpty ||
        kindName == null) {
      throw const FormatException('Invalid WebDAV resource reference');
    }
    final kind = WebDavResourceKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () =>
          throw const FormatException('Invalid WebDAV resource reference kind'),
    );
    final entryName = uri.queryParameters['entry'];
    if (kind != WebDavResourceKind.streamImage && entryName != null) {
      throw const FormatException('Invalid WebDAV stream entry reference');
    }
    return WebDavResourceRef(
      accountId: accountId,
      remotePath: remotePath,
      kind: kind,
      entryName: entryName,
    );
  }

  static bool isReference(String value) {
    try {
      parse(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => encode();

  @override
  bool operator ==(Object other) {
    return other is WebDavResourceRef &&
        other.accountId == accountId &&
        other.remotePath == remotePath &&
        other.kind == kind &&
        other.entryName == entryName;
  }

  @override
  int get hashCode => Object.hash(accountId, remotePath, kind, entryName);
}

class WebDavAccountMissingException implements Exception {
  final String accountId;
  const WebDavAccountMissingException(this.accountId);

  @override
  String toString() => 'WebDAV account no longer exists: $accountId';
}

class WebDavAccountMismatchException implements Exception {
  final String expected;
  final String actual;
  const WebDavAccountMismatchException(this.expected, this.actual);

  @override
  String toString() =>
      'WebDAV resource belongs to account $actual, not account $expected';
}
