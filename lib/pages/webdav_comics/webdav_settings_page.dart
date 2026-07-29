import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/webdav_comics/webdav_provider.dart';
import 'package:venera/utils/translations.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:venera/network/app_dio.dart';

import 'webdav_accounts.dart';
import 'webdav_client.dart';

class WebDavSettingsPage extends StatefulWidget {
  const WebDavSettingsPage({super.key});

  @override
  State<WebDavSettingsPage> createState() => _WebDavSettingsPageState();
}

class _WebDavSettingsPageState extends State<WebDavSettingsPage> {
  List<WebDavAccount> _accounts = [];
  String? _activeId;
  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _userController;
  late TextEditingController _passController;
  late TextEditingController _pathController;
  bool _testing = false;
  String? _testResult;
  bool _testSuccess = false;
  bool _editingNew = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _urlController = TextEditingController();
    _userController = TextEditingController();
    _passController = TextEditingController();
    _pathController = TextEditingController(text: '/');
    _reload();
  }

  void _reload() {
    _accounts = WebDavAccounts.list();
    _activeId = WebDavAccounts.activeId();
    final active = WebDavAccounts.active();
    if (active != null && !_editingNew) {
      _fill(active);
    } else if (_accounts.isEmpty) {
      _fillEmpty();
      _editingNew = true;
    }
    setState(() {});
  }

  void _fill(WebDavAccount a) {
    _nameController.text = a.name;
    _urlController.text = a.url;
    _userController.text = a.user;
    _passController.text = a.pass;
    _pathController.text = a.path.isEmpty ? '/' : a.path;
    _activeId = a.id;
    _editingNew = false;
  }

  void _fillEmpty() {
    _nameController.text = 'WebDAV ${_accounts.length + 1}';
    _urlController.text = '';
    _userController.text = '';
    _passController.text = '';
    _pathController.text = '/';
    _activeId = null;
    _editingNew = true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      await WebDavComicClient().testConnection(
        url: _urlController.text,
        user: _userController.text,
        pass: _passController.text,
        path: _pathController.text,
      );
      setState(() {
        _testSuccess = true;
        _testResult = 'Connection successful'.tl;
      });
    } catch (e) {
      setState(() {
        _testSuccess = false;
        _testResult = e.toString();
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim().isEmpty
        ? 'WebDAV'
        : _nameController.text.trim();
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      context.showMessage(message: 'Please enter server URL first'.tl);
      return;
    }
    if (_editingNew || _activeId == null) {
      final account = await WebDavAccounts.add(
        name: name,
        url: url,
        user: _userController.text,
        pass: _passController.text,
        path: _pathController.text,
      );
      _editingNew = false;
      _activeId = account.id;
    } else {
      final account = WebDavAccount(
        id: _activeId!,
        name: name,
        url: url,
        user: _userController.text,
        pass: _passController.text,
        path: _pathController.text,
      );
      await WebDavAccounts.update(account);
      await WebDavAccounts.setActive(account.id);
    }
    WebDavProvider().refresh();
    _reload();
    if (mounted) {
      context.showMessage(message: 'Settings saved'.tl);
    }
  }

  Future<void> _deleteCurrent() async {
    if (_editingNew || _activeId == null) {
      _fillEmpty();
      setState(() {});
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete'.tl),
        content: Text('Delete this account?'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete'.tl),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await WebDavAccounts.remove(_activeId!);
    WebDavProvider().refresh();
    _editingNew = false;
    _reload();
    if (_accounts.isEmpty) {
      _fillEmpty();
      setState(() {});
    }
  }

  void _browsePath() async {
    final url = _urlController.text.trim();
    final user = _userController.text.trim();
    final pass = _passController.text;
    if (url.isEmpty) {
      context.showMessage(message: 'Please enter server URL first'.tl);
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => _DirectoryPickerDialog(
        url: url,
        user: user,
        pass: pass,
        initialPath: _pathController.text,
        onSelected: (path) {
          setState(() {
            _pathController.text = path;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('WebDAV Comics'.tl),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop(),
            ),
            actions: [
              IconButton(
                tooltip: 'Add account'.tl,
                onPressed: () {
                  setState(() {
                    _fillEmpty();
                    _testResult = null;
                  });
                },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                _buildSectionHeader('Accounts'.tl),
                const SizedBox(height: 8),
                if (_accounts.isEmpty)
                  Text('No accounts. Fill the form and save.'.tl, style: ts.s14)
                else
                  ..._accounts.map((a) {
                    final selected = !_editingNew && a.id == _activeId;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: selected
                            ? context.colorScheme.primary
                            : context.colorScheme.outline,
                      ),
                      title: Text(a.name),
                      subtitle: Text(
                        a.url.isEmpty ? '-' : a.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: selected
                          ? Text('Active'.tl,
                              style: ts.s12
                                  .withColor(context.colorScheme.primary))
                          : null,
                      onTap: () async {
                        await WebDavAccounts.setActive(a.id);
                        WebDavProvider().refresh();
                        _editingNew = false;
                        _reload();
                      },
                    );
                  }),
                const SizedBox(height: 16),
                _buildSectionHeader(
                  _editingNew ? 'New Account'.tl : 'Edit Account'.tl,
                ),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _nameController,
                  label: 'Name'.tl,
                  hint: 'Home NAS',
                  icon: Icons.badge_outlined,
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  controller: _urlController,
                  label: 'Server URL'.tl,
                  hint: 'https://example.com/dav',
                  icon: Icons.link,
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  controller: _userController,
                  label: 'Username'.tl,
                  icon: Icons.person,
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  controller: _passController,
                  label: 'Password'.tl,
                  icon: Icons.lock,
                  obscure: true,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildTextField(
                        controller: _pathController,
                        label: 'Remote Path'.tl,
                        hint: '/',
                        icon: Icons.folder,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: IconButton.filled(
                        onPressed: _browsePath,
                        icon: const Icon(Icons.folder_open),
                        tooltip: 'Browse directories'.tl,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionHeader('Connection Test'.tl),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _testing ? null : _testConnection,
                        icon: _testing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_find),
                        label: Text(
                          _testing ? 'Testing...'.tl : 'Test Connection'.tl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: Text('Save'.tl),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _deleteCurrent,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    _editingNew ? 'Clear form'.tl : 'Delete account'.tl,
                  ),
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _testSuccess
                          ? Colors.green.withValues(alpha: 0.1)
                          : Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _testSuccess ? Colors.green : Colors.red,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _testSuccess ? Icons.check_circle : Icons.error,
                          color: _testSuccess ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _testResult!,
                            style: TextStyle(
                              color: _testSuccess ? Colors.green : Colors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                _buildSectionHeader('About'.tl),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'You can add multiple WebDAV accounts with different names, '
                        'switch the active account, then browse comics from that server.',
                        style: ts.s14,
                      ),
                      const SizedBox(height: 8),
                      Text('Supported formats:'.tl, style: ts.s14.bold),
                      Text(
                        '• Directory with image files (jpg, png, webp, etc.)\n'
                        '• Directory with chapter subdirectories\n'
                        '• CBZ/ZIP archive files',
                        style: ts.s14,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: ts.s18.bold.withColor(context.colorScheme.primary),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    IconData? icon,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon != null ? Icon(icon) : null,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}

class _DirectoryPickerDialog extends StatefulWidget {
  final String url;
  final String user;
  final String pass;
  final String initialPath;
  final void Function(String path) onSelected;

  const _DirectoryPickerDialog({
    required this.url,
    required this.user,
    required this.pass,
    required this.initialPath,
    required this.onSelected,
  });

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  late String _currentPath;
  List<_DirEntry> _entries = [];
  bool _loading = true;
  String? _error;
  webdav.Client? _client;

  @override
  void initState() {
    super.initState();
    _currentPath = _normalizePath(widget.initialPath);
    _client = webdav.newClient(
      widget.url,
      user: widget.user,
      password: widget.pass,
      adapter: RHttpAdapter(
        enableProxy: appdata.settings['webdavProxyEnabled'] != false,
      ),
    );
    _loadDir();
  }

  String _normalizePath(String path) {
    var result = path.trim().replaceAll('\\', '/');
    if (result.isEmpty) result = '/';
    if (!result.startsWith('/')) result = '/$result';
    if (!result.endsWith('/')) result = '$result/';
    return result;
  }

  Future<void> _loadDir() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await _client!.readDir(_currentPath);
      final dirs = <_DirEntry>[];
      for (final item in items) {
        final name = item.name ?? '';
        if (name.isEmpty || name == '.' || name == '..') continue;
        if (item.isDir == true) {
          dirs.add(_DirEntry(name: name));
        }
      }
      dirs.sort((a, b) => a.name.compareTo(b.name));
      setState(() {
        _entries = dirs;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _goInto(_DirEntry entry) {
    _currentPath = '$_currentPath${entry.name}/';
    _loadDir();
  }

  void _goUp() {
    if (_currentPath == '/') return;
    var withoutTrailing = _currentPath;
    if (withoutTrailing.endsWith('/')) {
      withoutTrailing =
          withoutTrailing.substring(0, withoutTrailing.length - 1);
    }
    final lastSlash = withoutTrailing.lastIndexOf('/');
    _currentPath = withoutTrailing.substring(0, lastSlash + 1);
    _loadDir();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: 'Select Directory'.tl,
      content: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    onPressed: _currentPath == '/' ? null : _goUp,
                    tooltip: 'Parent directory'.tl,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _currentPath,
                      style: ts.s14,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline,
                                  size: 36, color: Colors.red),
                              const SizedBox(height: 8),
                              Text(_error!,
                                  style: ts.s14, textAlign: TextAlign.center),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: _loadDir,
                                child: Text('Retry'.tl),
                              ),
                            ],
                          ),
                        )
                      : _entries.isEmpty
                          ? Center(
                              child: Text(
                                'No subdirectories'.tl,
                                style: ts.s14.copyWith(
                                  color: context.colorScheme.outline,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _entries.length,
                              itemBuilder: (context, index) {
                                final entry = _entries[index];
                                return ListTile(
                                  leading: const Icon(Icons.folder,
                                      color: Colors.amber),
                                  title: Text(entry.name),
                                  dense: true,
                                  onTap: () => _goInto(entry),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          onPressed: () {
            widget.onSelected(_currentPath);
            context.pop();
          },
          child: Text('Use This Directory'.tl),
        ),
      ],
    );
  }
}

class _DirEntry {
  final String name;
  const _DirEntry({required this.name});
}
