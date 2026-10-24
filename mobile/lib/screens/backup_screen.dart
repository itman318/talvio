import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/chat_backup.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';

/// Settings → Chat backup: save everything to Google Drive (or anywhere) and open old backups.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _withMedia = false;
  bool _busy = false;
  String _status = '';
  double? _progress;
  DateTime? _last;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final s = p.getString('last_backup_at');
      if (mounted && s != null) setState(() => _last = DateTime.tryParse(s));
    });
  }

  Future<String?> _askPassword({required bool creating}) async {
    final pw = TextEditingController();
    final pw2 = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(creating ? 'Protect with a password?' : 'Backup password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (creating) const Text('Anyone with the file can read an unprotected backup. A password encrypts it (AES-256). Don\'t forget it — it can\'t be recovered.'),
          TextField(controller: pw, obscureText: true, autofocus: true, decoration: const InputDecoration(labelText: 'Password')),
          if (creating) TextField(controller: pw2, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat password')),
        ]),
        actions: [
          if (creating) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('No password')),
          FilledButton(
            onPressed: () {
              if (creating && (pw.text.length < 6 || pw.text != pw2.text)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passwords must match and have 6+ characters')));
                return;
              }
              Navigator.pop(ctx, pw.text);
            },
            child: Text(creating ? 'Use password' : 'Open'),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final password = await _askPassword(creating: true);
    if (password == null || !mounted) return;
    final services = context.read<AppServices>();
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Collecting chats…';
    });
    try {
      final bytes = await ChatBackup(services).create(
        withMedia: _withMedia,
        password: password,
        progress: (done, total, label) {
          if (mounted) {
            setState(() {
              _progress = total == 0 ? null : done / total;
              _status = done >= total ? 'Packing…' : 'Backing up “$label” ($done/$total)';
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Choose where to save (Google Drive, Downloads…)');
      final name = '${AppConfig.appName}-backup-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.${password.isEmpty ? 'zip' : 'tlvbackup'}';
      final path = await FilePicker.platform.saveFile(dialogTitle: 'Save backup', fileName: name, bytes: bytes);
      if (!mounted) return;
      if (path == null) {
        setState(() => _status = 'Not saved');
        return;
      }
      final now = DateTime.now();
      (await SharedPreferences.getInstance()).setString('last_backup_at', now.toIso8601String());
      if (!mounted) return;
      setState(() {
        _last = now;
        _status = 'Backup saved (${fileSize(bytes.length)})';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Backup failed: ${friendlyError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _open() async {
    try {
      final r = await FilePicker.platform.pickFiles(withData: true);
      final f = r?.files.single;
      if (f == null) return;
      final Uint8List data = f.bytes ?? await File(f.path!).readAsBytes();
      String? pw;
      if (ChatBackup.isEncrypted(data)) {
        pw = await _askPassword(creating: false);
        if (pw == null) return;
      }
      final contents = await ChatBackup.open(data, password: pw);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => BackupViewerScreen(contents: contents)));
    } on BackupException catch (e) {
      if (mounted) showInfo(context, e.message);
    } catch (e) {
      if (mounted) showInfo(context, 'Could not open this file');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat backup')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(colors: [Brand.ink, Brand.inkSoft], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Row(children: [
            const Icon(Icons.cloud_done_rounded, color: Brand.primaryLight, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Your chats are in the cloud', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                  'Log in on any phone and they are there. A backup is an extra copy you keep yourself — on Google Drive, your computer or a memory card.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Last backup'),
              subtitle: Text(_last == null ? 'Never' : DateFormat('d MMM yyyy, HH:mm').format(_last!.toLocal())),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.perm_media_outlined),
              title: const Text('Include photos, videos and files'),
              subtitle: const Text('Up to 300 MB; files over 25 MB are skipped'),
              value: _withMedia,
              onChanged: _busy ? null : (v) => setState(() => _withMedia = v),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.backup_rounded),
          label: const Text('Back up now'),
        ),
        if (_busy || _status.isNotEmpty) ...[
          const SizedBox(height: 14),
          if (_busy) LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(4)),
          const SizedBox(height: 8),
          Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted)),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _open,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('Open a backup'),
        ),
        const SizedBox(height: 18),
        const Text(
          'Tip: in the save screen pick “Drive” to keep the backup in your Google Drive.\nVault chats are never backed up — their keys never leave this phone.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.muted, fontSize: 12),
        ),
      ]),
    );
  }
}

/// Read-only browser for a backup file.
class BackupViewerScreen extends StatelessWidget {
  const BackupViewerScreen({super.key, required this.contents});
  final BackupContents contents;

  @override
  Widget build(BuildContext context) {
    final chats = contents.chats;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Backup'),
          Text(DateFormat('d MMM yyyy, HH:mm').format(contents.createdAt), style: const TextStyle(fontSize: 12, color: Brand.muted)),
        ]),
      ),
      body: ListView.separated(
        itemCount: chats.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
        itemBuilder: (_, i) {
          final c = chats[i];
          return ListTile(
            leading: Avatar(id: (c['id'] as num).toInt(), name: '${c['title']}', size: 46),
            title: Text('${c['title']}'),
            subtitle: Text('${c['messages']} messages'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => _BackupChatScreen(title: '${c['title']}', items: contents.messages('${c['file']}'), contents: contents)),
            ),
          );
        },
      ),
    );
  }
}

class _BackupChatScreen extends StatelessWidget {
  const _BackupChatScreen({required this.title, required this.items, required this.contents});
  final String title;
  final List<(Message, String?)> items;
  final BackupContents contents;

  @override
  Widget build(BuildContext context) {
    final meId = (contents.manifest['account'] as Map?)?['id'];
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final (m, file) = items[items.length - 1 - i];
          final mine = m.senderId == meId;
          final bytes = file != null && m.type == 'image' ? contents.fileBytes(file) : null;
          return Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              decoration: BoxDecoration(
                color: mine ? Brand.ink : (dark ? const Color(0xFF171A2C) : Colors.white),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!mine && m.sender != null)
                  Text(m.sender!.name, style: TextStyle(color: colorForId(m.senderId ?? 0), fontWeight: FontWeight.w700, fontSize: 13)),
                if (bytes != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(bytes, width: 240, fit: BoxFit.cover)),
                  ),
                Text(m.type == 'text' ? m.text : m.preview, style: TextStyle(color: mine || dark ? Colors.white : Brand.ink)),
                const SizedBox(height: 2),
                Text(fmt.format(m.createdAt), style: TextStyle(fontSize: 11, color: mine || dark ? Colors.white60 : Brand.muted)),
              ]),
            ),
          );
        },
      ),
    );
  }
}
