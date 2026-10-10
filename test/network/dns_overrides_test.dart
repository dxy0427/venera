import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/dns_overrides.dart';

void main() {
  test('normalizes whitespace, case, FQDNs and both IP families', () {
    final result = parseDnsOverrides([
      (' EXAMPLE.COM. ', ' 127.0.0.1 ', true),
      ('images.example.com', ' [::1] ', false),
      (' ', ' ', false),
    ]);
    expect(result.addresses, {
      'example.com': '127.0.0.1',
      'images.example.com': '::1',
    });
    expect(result.noSni, ['example.com']);
  });

  test(
    'rejects URLs, paths, ports, invalid IPs, partial and duplicate rows',
    () {
      for (final row in [
        ('https://example.com', '127.0.0.1', false),
        ('example.com/path', '127.0.0.1', false),
        ('example.com:443', '127.0.0.1', false),
        ('*.example.com', '127.0.0.1', false),
        ('-bad.example', '127.0.0.1', false),
        ('example.com', '999.1.1.1', false),
        ('example.com', '127.0.0.1:80', false),
        ('example.com', '', false),
        ('', '127.0.0.1', false),
      ]) {
        expect(
          () => parseDnsOverrides([row]),
          throwsFormatException,
          reason: '$row',
        );
      }
      expect(
        () => parseDnsOverrides([
          ('example.com', '127.0.0.1', false),
          (' EXAMPLE.COM. ', '127.0.0.2', true),
        ]),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy or synced entries use the same normalization and disable switch',
    () {
      final old = {
        for (final key in [
          'enableDnsOverrides',
          'dnsOverrides',
          'dnsOverridesNoSni',
        ])
          key: appdata.settings[key],
      };
      addTearDown(
        () => old.forEach((key, value) => appdata.settings[key] = value),
      );
      appdata.settings['enableDnsOverrides'] = true;
      appdata.settings['dnsOverrides'] = {
        ' EXAMPLE.COM ': ' 127.0.0.1 ',
        'bad': 'invalid',
      };
      appdata.settings['dnsOverridesNoSni'] = [' EXAMPLE.COM '];
      expect(RHttpAdapter.getDnsOverrides(), {'example.com': '127.0.0.1'});
      expect(RHttpAdapter.getNoSniDomains(), {'example.com'});
      appdata.settings['enableDnsOverrides'] = false;
      expect(RHttpAdapter.getDnsOverrides(), isEmpty);
    },
  );
}
