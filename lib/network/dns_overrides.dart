import 'dart:io';

/// The same canonical host is used by the editor and both HTTP stacks.
String normalizeDnsHost(String input) {
  var host = input.trim().toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (host.isEmpty ||
      host.length > 253 ||
      !host.split('.').every(label.hasMatch)) {
    throw const FormatException('Enter a domain without a URL, port or path.');
  }
  return host;
}

String normalizeDnsAddress(String input) {
  var value = input.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  final address = InternetAddress.tryParse(value);
  if (address == null || value.contains('%')) {
    throw const FormatException('Enter a valid IPv4 or IPv6 address.');
  }
  return address.address;
}

/// Validate all rows before changing any settings. Entirely blank rows are
/// ignored; partial or duplicate rows must be corrected rather than lost.
({Map<String, String> addresses, List<String> noSni}) parseDnsOverrides(
  Iterable<(String, String, bool)> rows,
) {
  final addresses = <String, String>{};
  final noSni = <String>[];
  for (final (hostText, addressText, disableSni) in rows) {
    if (hostText.trim().isEmpty && addressText.trim().isEmpty) continue;
    final host = normalizeDnsHost(hostText);
    final address = normalizeDnsAddress(addressText);
    if (addresses.containsKey(host)) {
      throw const FormatException(
        'Each domain can only have one DNS override.',
      );
    }
    addresses[host] = address;
    if (disableSni) noSni.add(host);
  }
  return (addresses: addresses, noSni: noSni);
}
