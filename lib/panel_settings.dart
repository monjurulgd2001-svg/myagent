// Panel Upload Settings screen.
// Ports the extension's distSettingsModal (R2 Worker URL, queue path,
// Firebase accounts, default target, Test DB, Save). The Cloudinary
// AI Upscale credentials are NOT here: they stay backend-only,
// embedded in the app code (user order 2026-11-09).
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'studio_engine.dart';

class PanelSettingsScreen extends StatefulWidget {
  final StudioEngine engine;
  const PanelSettingsScreen({super.key, required this.engine});

  @override
  State<PanelSettingsScreen> createState() => _PanelSettingsScreenState();
}

class _AccountControllers {
  final TextEditingController name;
  final TextEditingController dbUrl;
  final TextEditingController secret;
  bool showSecret = false;
  _AccountControllers(DistAccount a)
      : name = TextEditingController(text: a.name),
        dbUrl = TextEditingController(text: a.dbUrl),
        secret = TextEditingController(text: a.secret);
  void dispose() {
    name.dispose();
    dbUrl.dispose();
    secret.dispose();
  }

  DistAccount toAccount() {
    final secVal = secret.text.trim();
    return DistAccount(
      name: name.text.trim(),
      dbUrl: dbUrl.text.trim(),
      secret: secVal,
    );
  }
}

class _PanelSettingsScreenState extends State<PanelSettingsScreen> {
  final TextEditingController _r2Ctrl = TextEditingController();
  final TextEditingController _queueCtrl =
      TextEditingController(text: 'wallpaperQueue');
  final List<_AccountControllers> _accounts = [];
  String _defaultTarget = 'spread';
  String _testStatus = 'Configure accounts above and click Test DB or Save.';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await widget.engine.loadDistConfig();
    _r2Ctrl.text = cfg.r2WorkerUrl;
    _queueCtrl.text = cfg.queuePath;
    _defaultTarget = cfg.defaultTarget;
    for (final c in _accounts) {
      c.dispose();
    }
    _accounts
      ..clear()
      ..addAll(cfg.accounts.map(_AccountControllers.new));
    if (_accounts.isEmpty) {
      _accounts.add(_AccountControllers(DistAccount(name: 'zedge_1')));
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _r2Ctrl.dispose();
    _queueCtrl.dispose();
    for (final c in _accounts) {
      c.dispose();
    }
    super.dispose();
  }

  String _r2Folder(String name) => widget.engine
      .r2FolderForAccountName(name.trim().isEmpty ? 'zedge_1' : name.trim());

  Future<void> _testAccount(_AccountControllers c) async {
    if (c.dbUrl.text.trim().isEmpty) {
      setState(() => _testStatus =
          'Enter a Firebase Database URL for "${c.name.text}" first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final secVal = c.secret.text.trim();
      final msg = await widget.engine
          .testPanelDatabase(dbUrl: c.dbUrl.text.trim(), secret: secVal);
      setState(() => _testStatus = '${c.name.text}: $msg');
    } catch (e) {
      setState(() => _testStatus = '${c.name.text}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final accounts = _accounts
        .map((c) => c.toAccount())
        .where((a) => a.name.isNotEmpty && a.dbUrl.isNotEmpty)
        .toList();
    final cfg = DistConfig(
      r2WorkerUrl: _r2Ctrl.text.trim(),
      queuePath: _queueCtrl.text.trim().isEmpty
          ? 'wallpaperQueue'
          : _queueCtrl.text.trim(),
      accounts: accounts,
      defaultTarget: _defaultTarget,
    );
    await widget.engine.saveDistConfig(cfg);
    setState(() => _testStatus =
        'Saved ${accounts.length} account(s) and the R2 Worker configuration.');
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  DistConfig _formConfig() {
    final accounts = _accounts
        .map((c) => c.toAccount())
        .where((a) => a.name.isNotEmpty && a.dbUrl.isNotEmpty)
        .toList();
    return DistConfig(
      r2WorkerUrl: _r2Ctrl.text.trim(),
      queuePath: _queueCtrl.text.trim().isEmpty
          ? 'wallpaperQueue'
          : _queueCtrl.text.trim(),
      accounts: accounts,
      defaultTarget: _defaultTarget,
    );
  }

  /// v169 — Backup: writes the R2 Worker URL, queue path and every
  /// Firebase account (URL + secret) to a .json file the user
  /// saves in Downloads / Drive. App data is deleted on uninstall,
  /// a file saved outside the app is not.
  Future<void> _backup() async {
    final cfg = _formConfig();
    if (cfg.r2WorkerUrl.isEmpty && cfg.accounts.isEmpty) {
      setState(() => _testStatus = 'Backup-er moto kichu nei — age R2/Firebase dao.');
      return;
    }
    setState(() => _busy = true);
    try {
      final json = const JsonEncoder.withIndent('  ').convert({
        'zedgeStudioBackup': 1,
        ...cfg.toJson(),
      });
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save settings backup',
        fileName: 'zedge_studio_settings_backup.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      setState(() => _testStatus = saved == null
          ? 'Backup cancel holo.'
          : 'Backup save holo: $saved\n'
              'Eta secret shoho — onno kauke dio na.');
    } catch (e) {
      setState(() => _testStatus = 'Backup korte giye vul: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// v169 — Restore: reads a backup .json, fills the form and saves.
  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final res =
          await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      if (res == null || res.files.isEmpty) return;
      final bytes = res.files.first.bytes;
      if (bytes == null) {
        setState(() => _testStatus = 'File-ta porte parlam na.');
        return;
      }
      final map = Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      if (map['zedgeStudioBackup'] == null &&
          map['r2WorkerUrl'] == null &&
          map['accounts'] == null) {
        setState(() => _testStatus = 'Eta Zedge Studio backup file na.');
        return;
      }
      final cfg = DistConfig.fromJson(map);
      await widget.engine.saveDistConfig(cfg);
      await _load();
      setState(() => _testStatus =
          'Restore holo: ${cfg.accounts.length} account + R2 Worker URL.');
    } catch (e) {
      setState(() => _testStatus = 'Restore korte giye vul: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Panel upload settings')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            'Finished sets upload to your R2 Worker and push a record to the account\'s Firebase queue.',
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _r2Ctrl,
            decoration: const InputDecoration(
              labelText: 'Cloudflare R2 Worker URL',
              hintText: 'https://your-worker.workers.dev',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _queueCtrl,
            decoration: const InputDecoration(
              labelText: 'Firebase Queue Path',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: Text('Firebase Database Accounts',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _accounts.add(
                    _AccountControllers(
                        DistAccount(name: 'zedge_${_accounts.length + 1}')))),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Account'),
              ),
            ],
          ),
          for (var i = 0; i < _accounts.length; i++) _accountCard(i),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: _defaultTarget,
            decoration: const InputDecoration(
              labelText: 'Default Upload Target',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                  value: 'spread',
                  child: Text('Spread (Auto-Rotate Across Accounts)')),
              for (final c in _accounts)
                if (c.name.text.trim().isNotEmpty)
                  DropdownMenuItem(
                      value: c.name.text.trim(),
                      child: Text(c.name.text.trim())),
            ],
            onChanged: (v) => setState(() => _defaultTarget = v ?? 'spread'),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_testStatus, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save Distribution Settings'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _backup,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Backup'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: const Text('Restore'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _accountCard(int i) {
    final c = _accounts[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: c.name,
                    decoration: const InputDecoration(
                      labelText: 'Account name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text('R2 Folder: ${_r2Folder(c.name.text)}/wallpaper/',
                      style: const TextStyle(fontSize: 11)),
                ),
                IconButton(
                  tooltip: 'Test connection',
                  onPressed: _busy ? null : () => _testAccount(c),
                  icon: const Icon(Icons.wifi_tethering, size: 19),
                ),
                IconButton(
                  tooltip: 'Remove account',
                  onPressed: () => setState(() {
                    _accounts[i].dispose();
                    _accounts.removeAt(i);
                  }),
                  icon: const Icon(Icons.delete_outline, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c.dbUrl,
              decoration: const InputDecoration(
                labelText: 'Firebase Realtime Database URL',
                hintText: 'https://your-project-default-rtdb.firebaseio.com',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c.secret,
              obscureText: !c.showSecret,
              decoration: InputDecoration(
                labelText: 'Database secret (optional)',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(c.showSecret
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () => setState(() => c.showSecret = !c.showSecret),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
