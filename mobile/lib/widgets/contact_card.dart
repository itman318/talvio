import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../screens/chat_screen.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import 'avatar.dart';

/// A shared contact inside a message: name, number/email, and "Message" when they use Talvio.
class ContactCardView extends StatelessWidget {
  const ContactCardView({super.key, required this.message, required this.accent});
  final Message message;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final c = Map<String, dynamic>.from((message.meta?['contact'] as Map?) ?? const {});
    final name = '${c['name'] ?? 'Contact'}';
    final phone = c['phone'] as String?;
    final email = c['email'] as String?;
    final userId = (c['user_id'] as num?)?.toInt();
    final me = context.read<AuthState>().me?.id;
    return SizedBox(
      width: 240,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Avatar(id: userId ?? name.hashCode, name: name, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              if (phone != null) Text(phone, style: const TextStyle(fontSize: 13)),
              if (email != null) Text(email, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          if (userId != null && userId != me)
            Expanded(
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: accent),
                onPressed: () async {
                  try {
                    final chat = await context.read<ChatStore>().openPrivateWith(userId);
                    if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Message'),
              ),
            ),
          Expanded(
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: accent),
              onPressed: () async {
                try {
                  final contact = Contact()
                    ..name.first = name
                    ..phones = [if (phone != null) Phone(phone)]
                    ..emails = [if (email != null) Email(email)];
                  await FlutterContacts.openExternalInsert(contact);
                } catch (_) {
                  await Clipboard.setData(ClipboardData(text: phone ?? email ?? name));
                  if (context.mounted) showInfo(context, 'Copied');
                }
              },
              child: const Text('Save'),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Composer → Contact: pick one from the phone's address book and share it.
Future<void> pickAndShareContact(BuildContext context, int chatId) async {
  try {
    if (!await FlutterContacts.requestPermission(readonly: true)) {
      if (context.mounted) showInfo(context, 'Allow contacts access to share a contact');
      return;
    }
    final picked = await FlutterContacts.openExternalPick();
    if (picked == null || !context.mounted) return;
    final full = await FlutterContacts.getContact(picked.id, withProperties: true) ?? picked;
    final phone = full.phones.isNotEmpty ? full.phones.first.normalizedNumber.isNotEmpty ? full.phones.first.normalizedNumber : full.phones.first.number : null;
    final email = full.emails.isNotEmpty ? full.emails.first.address : null;
    if (phone == null && email == null) {
      if (context.mounted) showInfo(context, 'This contact has no phone number or email');
      return;
    }
    if (!context.mounted) return;
    await context.read<ChatStore>().sendSpecial(chatId, 'contact', {
      'contact': {'name': full.displayName, 'phone': phone, 'email': email},
    }, meta: {
      'contact': {'name': full.displayName, 'phone': phone, 'email': email},
    }, text: full.displayName);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
