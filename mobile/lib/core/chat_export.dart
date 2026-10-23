import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../utils/format.dart';
import 'services.dart';

/// Chat → ⋮ → Export chat: saves the whole history as a readable text file where the user chooses.
Future<void> exportChat(BuildContext context, Chat chat) async {
  final api = context.read<AppServices>().api;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Preparing the export…'), duration: Duration(seconds: 30)));
  try {
    final all = <Message>[];
    int? before;
    for (var page = 0; page < 400; page++) {
      final data = Map<String, dynamic>.from(await api.get('/chats/${chat.id}/messages', query: {
        'limit': '100',
        if (before != null) 'before': '$before',
      }) as Map);
      final batch = (data['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      if (batch.isEmpty) break;
      all.addAll(batch);
      before = batch.map((m) => m.id).reduce((a, b) => a < b ? a : b);
      if (data['has_more'] != true) break;
    }
    all.sort((a, b) => a.id.compareTo(b.id));
    final fmt = DateFormat('dd/MM/yyyy, HH:mm');
    final b = StringBuffer()
      ..writeln('${AppConfig.appName} chat export — ${chat.title}')
      ..writeln('Exported ${fmt.format(DateTime.now())} · ${all.length} messages')
      ..writeln();
    for (final m in all) {
      if (m.deleted) continue;
      final who = m.isSystem ? '' : '${m.sender?.name ?? (m.senderId == null ? chat.title : 'Someone')}: ';
      final body = m.type == 'text' ? m.text : m.preview;
      b.writeln('[${fmt.format(m.createdAt.toLocal())}] $who$body');
    }
    messenger.hideCurrentSnackBar();
    final safe = chat.title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save chat',
      fileName: '${AppConfig.appName} - ${safe.isEmpty ? 'chat' : safe}.txt',
      bytes: utf8.encode(b.toString()),
    );
    if (path != null && context.mounted) showInfo(context, 'Chat saved');
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
  }
}
