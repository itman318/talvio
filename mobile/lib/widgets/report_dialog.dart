import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../utils/format.dart';

const _reasons = {
  'spam': 'Spam',
  'scam': 'Scam or fraud',
  'abuse': 'Abuse or harassment',
  'violence': 'Violence',
  'sexual': 'Sexual content',
  'illegal': 'Illegal content',
  'other': 'Other',
};

/// targetType: user | message | chat
Future<void> showReportDialog(BuildContext context, {required String targetType, required int targetId}) async {
  String reason = 'spam';
  final details = TextEditingController();
  final sent = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Report'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._reasons.entries.map((e) => RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: e.key,
                    groupValue: reason,
                    title: Text(e.value),
                    onChanged: (v) => setState(() => reason = v!),
                  )),
              TextField(
                controller: details,
                maxLength: 1000,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Details (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await ctx.read<AppServices>().api.post('/reports', {
                  'target_type': targetType,
                  'target_id': targetId,
                  'reason': reason,
                  'details': details.text.trim(),
                });
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) Navigator.pop(ctx, false);
                if (context.mounted) showError(context, e);
              }
            },
            child: const Text('Send report'),
          ),
        ],
      ),
    ),
  );
  if (sent == true && context.mounted) showInfo(context, 'Thanks — our team will review it.');
}
