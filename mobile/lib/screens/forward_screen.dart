import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/tali_emoji.dart';

enum _Kind { all, people, groups, channels, bots }

/// Pick up to 10 chats to forward messages to: search, filter, see who's picked, add a note, send.
class ForwardScreen extends StatefulWidget {
  const ForwardScreen({super.key, required this.fromChatId, required this.messageIds});

  final int fromChatId;
  final List<int> messageIds;

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  static const _max = 10;
  final List<int> _selected = []; // in the order they were picked
  final _search = TextEditingController();
  final _note = TextEditingController();
  String _q = '';
  _Kind _kind = _Kind.all;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    _note.dispose();
    super.dispose();
  }

  bool _fits(Chat c) => switch (_kind) {
        _Kind.all => true,
        _Kind.people => !c.isMulti && !c.isBot && !c.isSavedMessages,
        _Kind.groups => c.isGroup,
        _Kind.channels => c.isChannel,
        _Kind.bots => c.isBot,
      };

  /// Chats one can actually send to: not suspended, not blocked, not a deleted account, may post.
  List<Chat> _targets(ChatStore store) {
    final q = _q.trim().toLowerCase();
    final list = store.chats
        .where((c) => !c.isSuspended && c.peer?.blocked != true && c.peer?.deleted != true && (!c.isChannel || c.canPost))
        .where(_fits)
        .where((c) => q.isEmpty || c.title.toLowerCase().contains(q) || (c.peer?.username ?? '').toLowerCase().contains(q))
        .toList()
      ..sort((a, b) {
        // My Notes first, then the most recent chats
        if (a.isSavedMessages != b.isSavedMessages) return a.isSavedMessages ? -1 : 1;
        return b.sortTime.compareTo(a.sortTime);
      });
    return list;
  }

  String _subtitle(Chat c) {
    if (c.isSavedMessages) return 'Save it for later';
    if (c.isBot) return 'bot';
    if (c.isMulti) {
      final n = c.memberCount;
      return '$n ${c.isChannel ? (n == 1 ? 'subscriber' : 'subscribers') : (n == 1 ? 'member' : 'members')}';
    }
    if (c.peer?.online == true) return 'online';
    return c.lastMessage?.preview ?? '';
  }

  void _toggle(Chat c) {
    setState(() {
      if (_selected.contains(c.id)) {
        _selected.remove(c.id);
      } else if (_selected.length < _max) {
        _selected.add(c.id);
      } else {
        showInfo(context, 'You can forward to $_max chats at once');
      }
    });
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    final store = context.read<ChatStore>();
    final messenger = ScaffoldMessenger.of(context);
    final note = _note.text.trim();
    final names = _selected.map((id) => store.chatById(id)?.title ?? '').where((t) => t.isNotEmpty).toList();
    try {
      await store.forward(widget.fromChatId, widget.messageIds, List.of(_selected));
      if (note.isNotEmpty) {
        for (final id in _selected) {
          await store.sendText(id, note);
        }
      }
      if (!mounted) return;
      Navigator.pop(context);
      final what = widget.messageIds.length == 1 ? 'Message' : '${widget.messageIds.length} messages';
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(names.length == 1 ? '↪ $what forwarded to ${names.first}' : '↪ $what forwarded to ${names.length} chats')));
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final chats = _targets(store);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final count = widget.messageIds.length;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Text('Forward', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(
            _selected.isEmpty ? (count == 1 ? '1 message · pick up to $_max chats' : '$count messages · pick up to $_max chats') : '${_selected.length} of $_max selected',
            style: TextStyle(fontSize: 12.5, color: _selected.isEmpty ? Brand.muted : Brand.primary, fontWeight: FontWeight.w600),
          ),
        ]),
      ),
      body: Column(children: [
        // search
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _q = v),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search chats',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      }),
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        // filters
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final (k, label, icon) in [
                (_Kind.all, 'All', Icons.forum_rounded),
                (_Kind.people, 'People', Icons.person_rounded),
                (_Kind.groups, 'Groups', Icons.groups_rounded),
                (_Kind.channels, 'Channels', Icons.campaign_rounded),
                (_Kind.bots, 'Bots', Icons.smart_toy_rounded),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    avatar: Icon(icon, size: 16, color: _kind == k ? Colors.white : Brand.primary),
                    label: Text(label),
                    selected: _kind == k,
                    showCheckmark: false,
                    selectedColor: Brand.primary,
                    labelStyle: TextStyle(fontWeight: FontWeight.w700, color: _kind == k ? Colors.white : scheme.onSurface),
                    onSelected: (_) => setState(() => _kind = k),
                  ),
                ),
            ],
          ),
        ),
        // picked so far: tap a face to drop it
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: _selected.isEmpty
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: 86,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    children: [
                      for (final id in _selected)
                        if (store.chatById(id) case final c?)
                          GestureDetector(
                            onTap: () => _toggle(c),
                            child: SizedBox(
                              width: 66,
                              child: Column(children: [
                                Stack(clipBehavior: Clip.none, children: [
                                  Avatar(id: c.id, name: c.title, url: c.avatarAbsolute, size: 46, icon: c.isSavedMessages ? Icons.bookmark_rounded : null),
                                  Positioned(
                                    right: -4,
                                    top: -4,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
                                      child: const Icon(Icons.cancel_rounded, size: 17, color: Brand.muted),
                                    ),
                                  ),
                                ]),
                                const SizedBox(height: 4),
                                Text(c.isSavedMessages ? 'My Notes' : c.title.split(' ').first,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                              ]),
                            ),
                          ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: chats.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.search_off_rounded, size: 42, color: Brand.muted),
                    const SizedBox(height: 8),
                    Text(_q.isEmpty ? 'No chats here' : 'No chats match “$_q”', style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
                  ]),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: chats.length,
                  itemBuilder: (_, i) {
                    final c = chats[i];
                    final on = _selected.contains(c.id);
                    final sub = _subtitle(c);
                    return InkWell(
                      onTap: () => _toggle(c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        color: on ? Brand.primary.withValues(alpha: dark ? 0.16 : 0.07) : Colors.transparent,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Row(children: [
                          Stack(clipBehavior: Clip.none, children: [
                            Avatar(id: c.id, name: c.title, url: c.avatarAbsolute, size: 50, icon: c.isSavedMessages ? Icons.bookmark_rounded : null),
                            if (c.peer?.online == true)
                              Positioned(
                                right: -1,
                                bottom: -1,
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(color: Brand.accent, shape: BoxShape.circle, border: Border.all(color: scheme.surface, width: 2.5)),
                                ),
                              ),
                          ]),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                if (c.isChannel) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.campaign_rounded, size: 16, color: Brand.muted)),
                                if (c.isGroup) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.groups_rounded, size: 16, color: Brand.muted)),
                                Flexible(
                                  child: Text.rich(
                                    TextSpan(children: taliSpans(c.isSavedMessages ? 'My Notes' : c.title, const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ]),
                              if (sub.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(sub,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 13.5, color: sub == 'online' ? Brand.accent : Brand.muted, fontWeight: sub == 'online' ? FontWeight.w600 : FontWeight.w400)),
                                ),
                            ]),
                          ),
                          const SizedBox(width: 8),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            transitionBuilder: (ch, a) => ScaleTransition(scale: a, child: ch),
                            child: on
                                ? Container(
                                    key: const ValueKey('on'),
                                    width: 26,
                                    height: 26,
                                    decoration: const BoxDecoration(gradient: Brand.mineGradient, shape: BoxShape.circle),
                                    alignment: Alignment.center,
                                    child: Text('${_selected.indexOf(c.id) + 1}', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
                                  )
                                : Container(
                                    key: const ValueKey('off'),
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Brand.faint, width: 2)),
                                  ),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        // note + send, once something is picked
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: _selected.isEmpty
              ? const SizedBox(width: double.infinity)
              : SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 10, 10),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      border: Border(top: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE6E8F0))),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _note,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Add a message (optional)',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _busy ? null : _send,
                          child: Ink(
                            width: 48,
                            height: 48,
                            decoration: const BoxDecoration(gradient: Brand.mineGradient, shape: BoxShape.circle),
                            child: _busy
                                ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                                : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
        ),
      ]),
    );
  }
}
