import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

class WebDavAccount {
  final String id;
  String name;
  String url;
  String user;
  String pass;
  String path;

  WebDavAccount({
    required this.id,
    required this.name,
    required this.url,
    required this.user,
    required this.pass,
    this.path = '/',
  });

  factory WebDavAccount.fromJson(Map json) {
    return WebDavAccount(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'WebDAV').toString(),
      url: (json['url'] ?? '').toString(),
      user: (json['user'] ?? '').toString(),
      pass: (json['pass'] ?? '').toString(),
      path: (json['path'] ?? '/').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'user': user,
        'pass': pass,
        'path': path,
      };

  bool get isValid => url.trim().isNotEmpty;

  List<String> get configTriple => [url.trim(), user.trim(), pass.trim()];

  String get normalizedPath {
    var result = path.trim().replaceAll('\\', '/');
    if (result.isEmpty) result = '/';
    if (!result.startsWith('/')) result = '/$result';
    if (!result.endsWith('/')) result = '$result/';
    return result;
  }
}

class WebDavAccounts {
  WebDavAccounts._();

  static const _accountsKey = 'webdavComicAccounts';
  static const _activeKey = 'webdavComicActiveId';
  static const _legacyConfigKey = 'webdavComicSource';
  static const _legacyPathKey = 'webdavComicPath';

  static List<WebDavAccount> list() {
    _migrateLegacyIfNeeded();
    final raw = appdata.settings[_accountsKey];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map(WebDavAccount.fromJson)
        .where((e) => e.id.isNotEmpty)
        .toList();
  }

  static WebDavAccount? active() {
    final accounts = list();
    if (accounts.isEmpty) return null;
    final activeId = appdata.settings[_activeKey]?.toString();
    for (final a in accounts) {
      if (a.id == activeId) return a;
    }
    return accounts.first;
  }

  static String? activeId() => active()?.id;

  static Future<void> setActive(String id) async {
    final accounts = list();
    if (!accounts.any((e) => e.id == id)) return;
    appdata.settings[_activeKey] = id;
    await _syncLegacyActive();
    await appdata.saveData(false);
    _notifySourceChanged();
  }

  static Future<WebDavAccount> add({
    required String name,
    required String url,
    required String user,
    required String pass,
    String path = '/',
  }) async {
    final accounts = list();
    final account = WebDavAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim().isEmpty ? 'WebDAV' : name.trim(),
      url: url.trim(),
      user: user.trim(),
      pass: pass,
      path: path,
    );
    accounts.add(account);
    await _saveAll(accounts, activeId: account.id);
    return account;
  }

  static Future<void> update(WebDavAccount account) async {
    final accounts = list();
    final i = accounts.indexWhere((e) => e.id == account.id);
    if (i < 0) return;
    accounts[i] = account;
    await _saveAll(accounts, activeId: appdata.settings[_activeKey]?.toString());
  }

  static Future<void> remove(String id) async {
    final accounts = list();
    accounts.removeWhere((e) => e.id == id);
    String? nextActive = appdata.settings[_activeKey]?.toString();
    if (nextActive == id) {
      nextActive = accounts.isEmpty ? null : accounts.first.id;
    }
    await _saveAll(accounts, activeId: nextActive);
  }

  static Future<void> _saveAll(
    List<WebDavAccount> accounts, {
    String? activeId,
  }) async {
    appdata.settings[_accountsKey] =
        accounts.map((e) => e.toJson()).toList(growable: false);
    if (activeId != null && accounts.any((e) => e.id == activeId)) {
      appdata.settings[_activeKey] = activeId;
    } else if (accounts.isNotEmpty) {
      appdata.settings[_activeKey] = accounts.first.id;
    } else {
      appdata.settings[_activeKey] = null;
    }
    await _syncLegacyActive();
    await appdata.saveData(false);
    _notifySourceChanged();
  }

  static Future<void> _syncLegacyActive() async {
    final account = active();
    if (account == null || !account.isValid) {
      appdata.settings[_legacyConfigKey] = ['', '', ''];
      appdata.settings[_legacyPathKey] = '/';
      return;
    }
    appdata.settings[_legacyConfigKey] = account.configTriple;
    appdata.settings[_legacyPathKey] = account.normalizedPath;
  }

  static void _migrateLegacyIfNeeded() {
    final raw = appdata.settings[_accountsKey];
    if (raw is List && raw.isNotEmpty) return;

    String url = '', user = '', pass = '', path = '/';
    final legacy = appdata.settings[_legacyConfigKey];
    if (legacy is List && legacy.whereType<String>().length == 3) {
      final values = legacy.whereType<String>().toList();
      url = values[0];
      user = values[1];
      pass = values[2];
    }
    if (url.trim().isEmpty) {
      final sync = appdata.settings['webdav'];
      if (sync is List && sync.whereType<String>().length == 3) {
        final values = sync.whereType<String>().toList();
        url = values[0];
        user = values[1];
        pass = values[2];
      }
    }
    final legacyPath = appdata.settings[_legacyPathKey];
    if (legacyPath is String && legacyPath.trim().isNotEmpty) {
      path = legacyPath;
    }
    if (url.trim().isEmpty) {
      appdata.settings[_accountsKey] = <Map<String, dynamic>>[];
      return;
    }
    final account = WebDavAccount(
      id: 'legacy',
      name: 'WebDAV',
      url: url,
      user: user,
      pass: pass,
      path: path,
    );
    appdata.settings[_accountsKey] = [account.toJson()];
    appdata.settings[_activeKey] = account.id;
  }

  static void _notifySourceChanged() {
    final source = ComicSource.find('webdav');
    if (source == null) return;
    source.data['accounts'] = jsonEncode(list().map((e) => e.toJson()).toList());
    source.data['activeId'] = activeId();
    source.saveData();
    ComicSourceManager().notifyStateChange();
  }
}
