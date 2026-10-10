import 'package:dio/dio.dart';

/// Explicit context for JS network requests. QuickJS async continuations do
/// not inherit Dart zones; a scoped Network object carries this ID instead.
class SourceRequestContext {
  static int _nextId = 0;
  static final _tokens = <String, CancelToken>{};

  final String id = 'image-${_nextId++}';
  final CancelToken cancelToken;

  SourceRequestContext(this.cancelToken) {
    _tokens[id] = cancelToken;
  }

  static CancelToken? tokenFor(String? id) {
    if (id == null) return null;
    final token = _tokens[id];
    if (token == null) throw StateError('Image request context has ended');
    if (token.isCancelled) throw token.cancelError!;
    return token;
  }

  void dispose() => _tokens.remove(id);
}
