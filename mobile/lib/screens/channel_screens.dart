import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import '../theme/brand.dart';

// ------------------------------------------------------------------ create poll / quiz
/// Returns the poll JSON ({question, options, anonymous, multiple, quiz, correct_option, explanation}).
class CreatePollScreen extends StatefulWidget {
  const CreatePollScreen({super.key});

  @override
  State<CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<CreatePollScreen> {
  final _question = TextEditingController();
  final _explanation = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _anonymous = true;
  bool _multiple = false;
  bool _quiz = false;
  int? _correct;

  void _done() {
    final q = _question.text.trim();
    final opts = _options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (q.isEmpty) return showInfo(context, 'Write a question');
    if (opts.length < 2) return showInfo(context, 'Add at least 2 options');
    if (opts.toSet().length != opts.length) return showInfo(context, 'Options must be different');
    if (_quiz && (_correct == null || _correct! >= opts.length || _options[_correct!].text.trim().isEmpty)) {
      return showInfo(context, 'Tap the circle next to the correct answer');
    }
    // map the correct index to the filtered (non-empty) list
    int? correct;
    if (_quiz) {
      final text = _options[_correct!].text.trim();
      correct = opts.indexOf(text);
    }
    Navigator.pop(context, {
      'question': q,
      'options': opts,
      'anonymous': _anonymous,
      'multiple': _quiz ? false : _multiple,
      'quiz': _quiz,
      if (_quiz) 'correct_option': correct,
      if (_quiz && _explanation.text.trim().isNotEmpty) 'explanation': _explanation.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_quiz ? 'New quiz' : 'New poll'),
        actions: [TextButton(onPressed: _done, child: const Text('Create'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _question,
            maxLength: 300,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Question'),
          ),
          const SizedBox(height: 8),
          Text(_quiz ? 'Options — tap the circle to mark the correct answer' : 'Options', style: const TextStyle(fontWeight: FontWeight.w600)),
          for (var i = 0; i < _options.length; i++)
            Row(children: [
              if (_quiz)
                IconButton(
                  icon: Icon(_correct == i ? Icons.check_circle : Icons.radio_button_unchecked, color: _correct == i ? Colors.green : null),
                  onPressed: () => setState(() => _correct = i),
                ),
              Expanded(
                child: TextField(
                  controller: _options[i],
                  maxLength: 100,
                  decoration: InputDecoration(hintText: 'Option ${i + 1}', counterText: ''),
                ),
              ),
              if (_options.length > 2)
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() {
                    _options.removeAt(i);
                    if (_correct != null && _correct! >= _options.length) _correct = null;
                  }),
                ),
            ]),
          if (_options.length < 10)
            TextButton.icon(
              onPressed: () => setState(() => _options.add(TextEditingController())),
              icon: const Icon(Icons.add),
              label: const Text('Add option'),
            ),
          const Divider(),
          SwitchListTile(title: const Text('Anonymous voting'), value: _anonymous, onChanged: (v) => setState(() => _anonymous = v)),
          SwitchListTile(
            title: const Text('Multiple answers'),
            value: _multiple && !_quiz,
            onChanged: _quiz ? null : (v) => setState(() => _multiple = v),
          ),
          SwitchListTile(
            title: const Text('Quiz mode'),
            subtitle: const Text('One correct answer, shown after voting'),
            value: _quiz,
            onChanged: (v) => setState(() => _quiz = v),
          ),
          if (_quiz)
            TextField(
              controller: _explanation,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Explanation (optional)', hintText: 'Shown after answering'),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ scheduled messages
class ScheduledScreen extends StatefulWidget {
  const ScheduledScreen({super.key, required this.chatId});
  final int chatId;

  @override
  State<ScheduledScreen> createState() => _ScheduledScreenState();
}

class _ScheduledScreenState extends State<ScheduledScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<ChatStore>().listScheduled(widget.chatId);
      if (mounted) setState(() => _items = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled messages')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nothing scheduled.\nType a message and hold the send button to schedule it.', textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  children: items.map((m) {
                    final at = DateTime.parse(m['send_at'] as String).toLocal();
                    final failed = m['status'] == 'failed';
                    return ListTile(
                      leading: Icon(failed ? Icons.error_outline : Icons.schedule, color: failed ? Colors.red : null),
                      title: Text('${m['text']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(failed ? 'Failed: ${m['error'] ?? ''}' : 'Sends ${chatListTime(at)} at ${messageTime(at)}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          try {
                            await context.read<ChatStore>().cancelScheduled((m['id'] as num).toInt());
                            await _load();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    );
                  }).toList(),
                ),
    );
  }
}

// ------------------------------------------------------------------ statistics
class ChatStatsScreen extends StatefulWidget {
  const ChatStatsScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<ChatStatsScreen> createState() => _ChatStatsScreenState();
}

class _ChatStatsScreenState extends State<ChatStatsScreen> {
  Map<String, dynamic>? _s;

  @override
  void initState() {
    super.initState();
    context.read<ChatStore>().stats(widget.chat.id).then((s) {
      if (mounted) setState(() => _s = s);
    }).catchError((e) {
      if (mounted) showError(context, e);
    });
  }

  Widget _tile(String label, dynamic value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(compactNumber((value as num?)?.toInt() ?? 0), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              Text(label, style: const TextStyle(color: Brand.muted, fontSize: 12)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final members = widget.chat.isChannel ? 'Subscribers' : 'Members';
    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Row(children: [_tile(members, s['members']), _tile('New in 7 days', s['joined_7d'])]),
                Row(children: [_tile('Posts (30 days)', s['posts_30d']), _tile('Avg. views / post', s['avg_views_30d'])]),
                Row(children: [_tile('Total views', s['views_total']), _tile('Reactions (30 days)', s['reactions_30d'])]),
                const SizedBox(height: 12),
                Text('New $members — last 30 days', style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SizedBox(height: 120, child: _Bars(points: (s['joins_30d'] as List).map((p) => ((p as Map)['count'] as num).toInt()).toList())),
                const SizedBox(height: 16),
                const Text('Top posts (30 days)', style: TextStyle(fontWeight: FontWeight.w600)),
                ...(s['top_posts'] as List).map((p) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(((p as Map)['text'] as String?)?.isNotEmpty == true ? p['text'] as String : '[${p['type']}]',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Text('👁 ${compactNumber((p['views'] as num).toInt())}'),
                    )),
              ],
            ),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars({required this.points});
  final List<int> points;

  @override
  Widget build(BuildContext context) {
    final maxV = points.fold<int>(1, (m, v) => v > m ? v : m);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: points
          .map((v) => Expanded(
                child: Tooltip(
                  message: '$v',
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    height: v == 0 ? 2 : 110 * v / maxV,
                    color: v == 0 ? Colors.black12 : Brand.primary,
                  ),
                ),
              ))
          .toList(),
    );
  }
}

// ------------------------------------------------------------------ new channel
class NewChannelScreen extends StatefulWidget {
  const NewChannelScreen({super.key});

  @override
  State<NewChannelScreen> createState() => _NewChannelScreenState();
}

class _NewChannelScreenState extends State<NewChannelScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _username = TextEditingController();
  bool _public = false;
  String? _avatar;
  bool _busy = false;

  Future<void> _create() async {
    if (_title.text.trim().isEmpty) {
      showInfo(context, 'Enter a channel name');
      return;
    }
    if (_public && _username.text.trim().length < 5) {
      showInfo(context, 'Public channels need a link of at least 5 characters');
      return;
    }
    setState(() => _busy = true);
    try {
      final chat = await context.read<ChatStore>().createChannel(
            title: _title.text.trim(),
            description: _desc.text.trim(),
            username: _public ? _username.text.trim().replaceFirst('@', '') : null,
            avatarPath: _avatar,
          );
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New channel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            GestureDetector(
              onTap: () async {
                final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
                if (x != null) setState(() => _avatar = x.path);
              },
              child: CircleAvatar(
                radius: 32,
                backgroundColor: Brand.primary,
                backgroundImage: _avatar != null ? FileImage(File(_avatar!)) : null,
                child: _avatar == null ? const Icon(Icons.add_a_photo, color: Colors.white) : null,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _title,
                autofocus: true,
                maxLength: 128,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Channel name'),
              ),
            ),
          ]),
          TextField(controller: _desc, maxLength: 255, maxLines: 3, decoration: const InputDecoration(labelText: 'Description (optional)')),
          const SizedBox(height: 8),
          const Text('Only admins can post in a channel. Subscribers read, react and vote in polls.', style: TextStyle(color: Brand.muted)),
          RadioListTile<bool>(
            value: false,
            groupValue: _public,
            title: const Text('Private channel'),
            subtitle: const Text('People join with an invite code'),
            onChanged: (v) => setState(() => _public = v!),
          ),
          RadioListTile<bool>(
            value: true,
            groupValue: _public,
            title: const Text('Public channel'),
            subtitle: const Text('Anyone can find it in search and join'),
            onChanged: (v) => setState(() => _public = v!),
          ),
          if (_public)
            TextField(
              controller: _username,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Public link', prefixText: '@', helperText: '5–32 letters, digits or _'),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : _create,
        child: _busy ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.check),
      ),
    );
  }
}

// ------------------------------------------------------------------ public group / channel preview
class PublicChatPreviewScreen extends StatefulWidget {
  const PublicChatPreviewScreen({super.key, required this.info});
  final Map<String, dynamic> info;

  @override
  State<PublicChatPreviewScreen> createState() => _PublicChatPreviewScreenState();
}

class _PublicChatPreviewScreenState extends State<PublicChatPreviewScreen> {
  bool _busy = false;

  Future<void> _join() async {
    final store = context.read<ChatStore>();
    final id = (widget.info['chat_id'] as num).toInt();
    setState(() => _busy = true);
    try {
      final chat = widget.info['is_member'] == true ? await store.getChat(id) : await store.joinPublic(id);
      if (!mounted) return;
      if (chat == null) {
        showInfo(context, 'Request sent — the admins will review it');
        Navigator.pop(context);
        return;
      }
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final isChannel = i['type'] == 'channel';
    final avatar = i['avatar_url'] as String?;
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Avatar(
              id: (i['chat_id'] as num).toInt(),
              name: '${i['title']}',
              url: avatar == null ? null : AppConfig.absolute(avatar),
              size: 96,
            ),
          ),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(child: Text('${i['title']}', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center)),
            if (i['is_verified'] == true) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified, color: Brand.primary)),
          ]),
          Text(
            '${i['username'] != null ? '@${i['username']} · ' : ''}${i['member_count']} ${isChannel ? 'subscribers' : 'members'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Brand.muted),
          ),
          if ('${i['description'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('${i['description']}', textAlign: TextAlign.center),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _join,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(i['is_member'] == true
                ? 'Open'
                : (isChannel ? 'Join channel' : (i['join_approval'] == true ? 'Request to join' : 'Join group'))),
          ),
        ],
      ),
    );
  }
}
