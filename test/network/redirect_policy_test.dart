import 'dart:io';
import 'dart:typed_data';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';

/// The actual redirect loop and TLS/DNS policy, with dart:io as the transport
/// so these tests can run without the platform-specific Rust plugin binary.
class _LocalTransport extends RHttpAdapter {
  _LocalTransport() : super(enableProxy: false);
  final policies = <(Uri, rhttp.ClientSettings)>[];
  final transport = IOHttpClientAdapter(
    createHttpClient: () => createDartIoHttpClient(null),
  );

  @override
  Future<ResponseBody> fetchOnce(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    policies.add((options.uri, await settingsFor(options)));
    return transport.fetch(
      options.copyWith(followRedirects: false),
      requestStream,
      cancelFuture,
    );
  }

  @override
  void close({bool force = false}) => transport.close(force: force);
}

void main() {
  late HttpServer origin;
  late HttpServer target;
  late Dio dio;
  late _LocalTransport adapter;
  late String url;
  late String targetUrl;

  setUp(() async {
    final old = {
      for (final key in [
        'enableDnsOverrides',
        'dnsOverrides',
        'dnsOverridesNoSni',
        'ignoreBadCertificate',
      ])
        key: appdata.settings[key],
    };
    addTearDown(
      () => old.forEach((key, value) => appdata.settings[key] = value),
    );
    appdata.settings['enableDnsOverrides'] = true;
    appdata.settings['dnsOverrides'] = {
      'fronting.test': '127.0.0.1',
      'ordinary.test': '127.0.0.1',
    };
    appdata.settings['dnsOverridesNoSni'] = ['fronting.test'];
    appdata.settings['ignoreBadCertificate'] = false;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://fronting.test:${origin.port}/start?old=1';
    targetUrl = 'http://ordinary.test:${target.port}/end?new=2';
    adapter = _LocalTransport();
    dio = Dio()..httpClientAdapter = adapter;
  });

  test(
    'a real TLS redirect restores certificate verification for the next host',
    () async {
      final security = SecurityContext()
        ..useCertificateChain('test/fixtures/tls/cert.pem')
        ..usePrivateKey('test/fixtures/tls/key.pem');
      final tls = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        security,
      );
      addTearDown(() => tls.close(force: true));
      var acceptedRequests = 0;
      tls.listen(
        (request) async {
          acceptedRequests++;
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'https://ordinary.test:${tls.port}/end',
          );
          await request.response.close();
        },
        onError: (Object error) {
          // The client rejecting our untrusted certificate is the expected second
          // handshake; it must not accept the original host's no-SNI exception.
          if (error is! HandshakeException) throw error;
        },
      );
      await expectLater(
        dio.get('https://fronting.test:${tls.port}/start'),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'TLS error',
            isA<HandshakeException>(),
          ),
        ),
      );
      expect(acceptedRequests, 1);
      expect(adapter.policies, hasLength(2));
      expect(adapter.policies.last.$2.tlsSettings!.verifyCertificates, true);
    },
  );

  tearDown(() async {
    dio.close(force: true);
    await origin.close(force: true);
    await target.close(force: true);
  });

  test(
    'cross-host redirects recompute TLS policy and strip credentials',
    () async {
      origin.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer synthetic');
        request.response.statusCode = 302;
        request.response.headers.set('location', targetUrl);
        await request.response.close();
      });
      target.listen((request) async {
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('cookie'), isNull);
        expect(request.uri.query, 'new=2');
        request.response.write('ok');
        await request.response.close();
      });
      final response = await dio.get(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer synthetic',
            'Cookie': 'session=synthetic',
          },
        ),
      );
      expect(response.data, 'ok');
      expect(response.realUri.toString(), targetUrl);
      expect(adapter.policies, hasLength(2));
      expect(adapter.policies[0].$2.tlsSettings!.sni, false);
      expect(adapter.policies[0].$2.tlsSettings!.verifyCertificates, false);
      expect(adapter.policies[1].$2.tlsSettings!.sni, true);
      expect(adapter.policies[1].$2.tlsSettings!.verifyCertificates, true);
    },
  );

  test(
    'same-host relative redirects retain credentials and query is not duplicated',
    () async {
      origin.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer synthetic');
        if (request.uri.path == '/start') {
          request.response.statusCode = 307;
          request.response.headers.set('location', '/end?new=2');
        } else {
          expect(request.uri.query, 'new=2');
          request.response.write('ok');
        }
        await request.response.close();
      });
      final response = await dio.get(
        url,
        options: Options(headers: {'Authorization': 'Bearer synthetic'}),
      );
      expect(response.data, 'ok');
      expect(response.redirects, hasLength(1));
    },
  );

  test(
    'followRedirects false exposes WebDAV Location without another request',
    () async {
      origin.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set('location', targetUrl);
        await request.response.close();
      });
      final response = await dio.get(
        url,
        options: Options(followRedirects: false, validateStatus: (_) => true),
      );
      expect(response.statusCode, 302);
      expect(response.headers.value('location'), targetUrl);
      expect(adapter.policies, hasLength(1));
    },
  );

  test('redirect loops respect the caller limit', () async {
    origin.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', '/start');
      await request.response.close();
    });
    await expectLater(
      dio.get(url, options: Options(maxRedirects: 2)),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'cause',
          isA<RedirectException>(),
        ),
      ),
    );
    expect(adapter.policies, hasLength(3));
  });

  test(
    'POST 303 becomes GET without replaying the upload or its headers',
    () async {
      origin.listen((request) async {
        expect(request.method, 'POST');
        await request.drain<void>();
        request.response.statusCode = 303;
        request.response.headers.set('location', targetUrl);
        await request.response.close();
      });
      target.listen((request) async {
        expect(request.method, 'GET');
        expect(request.headers.contentLength, -1);
        request.response.write('ok');
        await request.response.close();
      });
      expect((await dio.post(url, data: 'upload')).data, 'ok');
    },
  );

  test(
    '307 streaming upload is returned instead of replaying an exhausted stream',
    () async {
      origin.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 307;
        request.response.headers.set('location', targetUrl);
        await request.response.close();
      });
      final response = await dio.post(
        url,
        data: Stream.value([1, 2, 3]),
        options: Options(validateStatus: (_) => true),
      );
      expect(response.statusCode, 307);
      expect(adapter.policies, hasLength(1));
    },
  );
}
