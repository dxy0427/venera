import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/dns_overrides.dart';
import 'package:venera/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error(
      "Network",
      "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}",
    );
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    var headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      "Network",
      "Response ${response.realUri.toString()} ${response.statusCode}\n"
          "headers:\n$headers\n$content",
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String headerMask = "********";
    const String dataMask = "****** DATA_PROTECTED ******";
    Log.info(
      "Network",
      "${options.method} ${options.uri}\n"
          "headers:\n${options.extra.containsKey("maskHeadersInLog") ? options.headers.map((key, value) => MapEntry(key, options.extra["maskHeadersInLog"].contains(key) ? headerMask : value)) : options.headers}\n"
          "data:\n${options.extra["maskDataInLog"] == true ? dataMask : options.data}",
    );
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = RHttpAdapter();
    if (App.isInitialized) {
      interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Map<String, Completer<void>> _requests = {};

  @override
  Future<Response<T>> fetch<T>(RequestOptions requestOptions) async {
    final headers = Map<String, dynamic>.from(requestOptions.headers);
    var serialize = false;
    headers.removeWhere((key, value) {
      if (key.toLowerCase() != 'prevent-parallel') return false;
      serialize = value.toString() == 'true';
      return true;
    });
    final options = requestOptions.copyWith(headers: headers);
    if (!serialize) return super.fetch<T>(options);

    // Queue by the resolved URL, across Dio instances. Cancelled waiters stay
    // in the chain until their predecessor finishes, so they cannot unlock it.
    final key = options.uri.replace(fragment: '').toString();
    final previous = _requests[key];
    final lease = Completer<void>();
    _requests[key] = lease;
    final token = options.cancelToken;
    var acquired = false;
    var streaming = false;
    void release() {
      if (identical(_requests[key], lease)) _requests.remove(key);
      if (!lease.isCompleted) lease.complete();
    }

    try {
      if (previous != null) {
        await Future.any<void>([
          previous.future,
          if (token != null) token.whenCancel.then((error) => throw error),
        ]);
      }
      if (token?.isCancelled == true) throw token!.cancelError!;
      acquired = true;
      final response = await super.fetch<T>(options);
      final body = response.data;
      if (body is ResponseBody) {
        body.stream = _releaseAfterStream(body.stream, release);
        streaming = true;
        token?.whenCancel.then((_) => release());
      }
      return response;
    } finally {
      if (!streaming) {
        if (!acquired && previous != null) {
          unawaited(previous.future.then((_) => release()));
        } else {
          release();
        }
      }
    }
  }
}

Stream<Uint8List> _releaseAfterStream(
  Stream<Uint8List> stream,
  void Function() release,
) {
  late StreamSubscription<Uint8List> subscription;
  final controller = StreamController<Uint8List>();
  controller.onListen = () {
    subscription = stream.listen(
      controller.add,
      onError: (Object error, StackTrace stack) {
        release();
        controller.addError(error, stack);
      },
      onDone: () {
        release();
        controller.close();
      },
    );
  };
  controller.onPause = () => subscription.pause();
  controller.onResume = () => subscription.resume();
  controller.onCancel = () async {
    try {
      await subscription.cancel();
    } finally {
      release();
    }
  };
  return controller.stream;
}

class RHttpAdapter implements HttpClientAdapter {
  final bool enableProxy;

  RHttpAdapter({this.enableProxy = true});

  Future<rhttp.ClientSettings> settingsFor(RequestOptions options) async {
    var proxy = enableProxy ? await getProxy() : null;
    final overrides = getDnsOverrides();
    final noSniDomains = getNoSniDomains();
    final host = options.uri.host.toLowerCase().replaceFirst(
      RegExp(r'\.$'),
      '',
    );
    // Domain fronting: connect to the override IP without SNI. The override
    // server's certificate does not match the original hostname (e.g. the
    // site's own servers present their main certificate for any host), so
    // certificate verification is skipped for these domains only.
    final fronting = overrides.containsKey(host) && noSniDomains.contains(host);

    return rhttp.ClientSettings(
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      // Redirects are handled one hop at a time in fetch, since TLS settings
      // are client-wide in rhttp and must be recalculated for the next host.
      redirectSettings: const rhttp.RedirectSettings.none(),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(
        overrides: {
          for (var entry in overrides.entries) entry.key: [entry.value],
          if (overrides.containsKey(host)) options.uri.host: [overrides[host]!],
        },
      ),
      tlsSettings: rhttp.TlsSettings(
        // The domain name is not sent in the TLS handshake only for domains
        // marked in the DNS overrides, so other sources are unaffected.
        sni: !fronting,
        verifyCertificates:
            !fronting && appdata.settings['ignoreBadCertificate'] != true,
      ),
    );
  }

  static Map<String, String> getDnsOverrides() {
    if (appdata.settings['enableDnsOverrides'] != true) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, String>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          try {
            result[normalizeDnsHost(entry.key)] = normalizeDnsAddress(
              entry.value,
            );
          } on FormatException {
            // Old/synced invalid entries must not break unrelated requests.
          }
        }
      }
    }
    return result;
  }

  /// Domains whose name should not be sent in the TLS handshake (SNI),
  /// e.g. to bypass SNI-based blocking of a DNS override entry.
  static Set<String> getNoSniDomains() {
    var result = <String>{};
    var config = appdata.settings['dnsOverridesNoSni'];
    if (config is List) {
      for (var domain in config) {
        if (domain is String) {
          try {
            result.add(normalizeDnsHost(domain));
          } on FormatException {
            // The editor reports invalid new entries before saving them.
          }
        }
      }
      return result;
    }
    // Saved before the per-domain option existed: fall back to the legacy
    // global switch, which applied to all overridden domains.
    if (appdata.settings['sni'] == false) {
      result.addAll(getDnsOverrides().keys);
    }
    return result;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var current = options;
    var body = requestStream;
    var cancelled = false;
    cancelFuture?.then((_) => cancelled = true);
    final redirects = <RedirectRecord>[];
    while (true) {
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'Request cancelled',
        );
      }
      final response = await fetchOnce(current, body, cancelFuture);
      final location = response.headers['location']?.firstOrNull;
      final code = response.statusCode;
      final isRedirect = {301, 302, 303, 307, 308}.contains(code);
      // A streaming upload cannot be replayed for a 307/308. Like reqwest,
      // expose that response to the caller instead of resending an empty body.
      if (!options.followRedirects ||
          !isRedirect ||
          location == null ||
          ((code == 307 || code == 308) && body != null)) {
        response.redirects = redirects;
        return response;
      }
      await response.stream.listen(null, onError: (Object _) {}).cancel();
      if (redirects.length >= options.maxRedirects) {
        throw DioException(
          requestOptions: options,
          error: const RedirectException('Too many redirects', []),
        );
      }
      final next = current.uri.resolve(location);
      if (!{'http', 'https'}.contains(next.scheme) || next.host.isEmpty) {
        throw DioException(
          requestOptions: options,
          error: const FormatException('Invalid redirect URL'),
        );
      }
      final headers = Map<String, dynamic>.from(current.headers);
      var method = current.method;
      if (code == 301 || code == 302 || code == 303) {
        body = null;
        if (method != 'GET' && method != 'HEAD') method = 'GET';
        headers.removeWhere(
          (key, _) => {
            'content-length',
            'content-type',
            'transfer-encoding',
          }.contains(key.toLowerCase()),
        );
      }
      final sameOrigin =
          next.scheme == current.uri.scheme &&
          next.host == current.uri.host &&
          next.port == current.uri.port;
      if (!sameOrigin) {
        headers.removeWhere(
          (key, _) => {
            'authorization',
            'proxy-authorization',
            'cookie',
            'host',
          }.contains(key.toLowerCase()),
        );
      }
      if (current.uri.scheme == 'https' && next.scheme == 'http') {
        headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
      }
      redirects.add(RedirectRecord(code, method, next));
      current = current.copyWith(
        path: next.toString(),
        baseUrl: '',
        queryParameters: {},
        method: method,
        headers: headers,
      );
    }
  }

  /// Perform one HTTP exchange. Keeping the transport separate also permits
  /// exercising the redirect policy against a local test server.
  Future<ResponseBody> fetchOnce(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    // Forward dio's cancellation (CancelToken / abort) to the underlying Rust
    // request so cancelled downloads stop transferring bytes instead of only
    // failing after the whole body has been read.
    final rhttpCancelToken = rhttp.CancelToken();
    cancelFuture?.then((_) => rhttpCancelToken.cancel());

    var res = await rhttp.Rhttp.request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      settings: await settingsFor(options),
      expectBody: rhttp.HttpExpectBody.stream,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
      cancelToken: rhttpCancelToken,
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    final code = res.statusCode;
    late StreamSubscription<Uint8List> subscription;
    final controller = StreamController<Uint8List>();
    controller.onListen = () {
      subscription = res.body.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
    };
    controller.onPause = () => subscription.pause();
    controller.onResume = () => subscription.resume();
    controller.onCancel = () async {
      unawaited(rhttpCancelToken.cancel());
      await subscription.cancel();
    };
    return ResponseBody(
      controller.stream,
      code,
      statusMessage: _getStatusMessage(code),
      isRedirect:
          code == 301 ||
          code == 302 ||
          code == 303 ||
          code == 307 ||
          code == 308,
      headers: headers,
    );
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}

/// Creates a dart:io [HttpClient] which applies the app's network settings:
/// the proxy, DNS overrides, per-domain SNI bypass and certificate
/// verification.
///
/// JS comic sources can request the dart:io HTTP stack with the
/// "http_client": "dart:io" request header. Without this factory, those
/// requests would ignore the settings above, since they bypass [RHttpAdapter].
HttpClient createDartIoHttpClient(String? proxy) {
  var client = HttpClient()
    ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
  var ignoreBadCertificate = appdata.settings['ignoreBadCertificate'] == true;
  var overrides = RHttpAdapter.getDnsOverrides();
  var noSniDomains = RHttpAdapter.getNoSniDomains();
  if (overrides.isEmpty) {
    if (ignoreBadCertificate) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost != null) {
      // The HTTP client performs the TLS handshake itself after the
      // proxy tunnel has been established.
      var task = await Socket.startConnect(proxyHost, proxyPort ?? 80);
      return ConnectionTask.fromSocket(task.socket, task.cancel);
    }
    var port = uri.port;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    var override = overrides[host];
    if (uri.scheme != "https") {
      var task = await Socket.startConnect(override ?? uri.host, port);
      return ConnectionTask.fromSocket(task.socket, task.cancel);
    }
    bool Function(X509Certificate)? onBadCertificate = ignoreBadCertificate
        ? (_) => true
        : null;
    if (override == null) {
      var task = await SecureSocket.startConnect(
        uri.host,
        port,
        onBadCertificate: onBadCertificate,
      );
      return ConnectionTask.fromSocket(task.socket, task.cancel);
    }
    var task = await Socket.startConnect(override, port);
    Future<SecureSocket> socket;
    if (noSniDomains.contains(host)) {
      // Bypass SNI: the domain name is not sent in the TLS handshake.
      // dart:io cannot omit the SNI extension, so the override IP is sent
      // instead (rhttp sends no SNI at all). The certificate cannot match
      // the IP address, so it is not verified.
      socket = task.socket.then(
        (socket) => SecureSocket.secure(socket, onBadCertificate: (_) => true),
      );
    } else {
      socket = task.socket.then(
        (socket) => SecureSocket.secure(
          socket,
          host: uri.host,
          onBadCertificate: onBadCertificate,
        ),
      );
    }
    return ConnectionTask.fromSocket(socket, task.cancel);
  };
  return client;
}
