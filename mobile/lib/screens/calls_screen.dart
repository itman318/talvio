import '../widgets/mascot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config.dart';
import '../state/chat_store.dart';
import '../widgets/premium.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/call_manager.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../theme/brand.dart';

/// Starts a call after the usual checks (feature switch, already on a call).
Future<void> startCall(BuildContext context, AppUser user, {required bool video}) async {
  final calls = context.read<CallManager>();
  if (calls.active) {
    showInfo(context, 'Finish your current call first');
    return;
  }
  await calls.start(user, video: video);
}

/// Call history: all / missed, tap to call back, long-press to delete.
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  bool _missedOnly = false;
  List<CallInfo>? _calls;
  bool _loadingMore = false;
  bool _end = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final api = context.read<AppServices>().api;
    if (more) {
      if (_loadingMore || _end || _calls == null || _calls!.isEmpty) return;
      _loadingMore = true;
    }
    try {
      final q = <String, String>{
        if (_missedOnly) 'missed': '1',
        if (more) 'before': '${_calls!.last.id}',
      };
      final data = await api.get('/calls', query: q) as List;
      final list = data.map((j) => CallInfo.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      if (!mounted) return;
      setState(() {
        _end = list.length < 50;
        _calls = more ? [...?_calls, ...list] : list;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _delete(CallInfo c) async {
    try {
      await context.read<AppServices>().api.post('/calls/delete', {'ids': [c.id]});
      if (mounted) setState(() => _calls?.removeWhere((x) => x.id == c.id));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _clearAll() async {
    if (!await confirm(context, 'Clear call history?', 'This only clears your list.', ok: 'Clear', danger: true)) return;
    if (!mounted) return;
    try {
      await context.read<AppServices>().api.post('/calls/delete', {'all': true});
      if (mounted) setState(() => _calls = []);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final calls = _calls;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls'),
        actions: [
          IconButton(
            tooltip: 'Call links',
            icon: const Icon(Icons.add_link_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CallLinksScreen())),
          ),
          PopupMenuButton<String>(
            onSelected: (_) => _clearAll(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Clear call history'))],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              segments: const [
                ButtonSegment(value: false, label: Text('All')),
                ButtonSegment(value: true, label: Text('Missed')),
              ],
              selected: {_missedOnly},
              onSelectionChanged: (s) {
                setState(() {
                  _missedOnly = s.first;
                  _calls = null;
                });
                _load();
              },
            ),
          ),
        ),
      ),
      body: calls == null
          ? const Center(child: CircularProgressIndicator())
          : calls.isEmpty
              ? EmptyState(
                  pose: _missedOnly ? TaviPose.cool : TaviPose.sleep,
                  title: _missedOnly ? 'No missed calls' : 'No calls yet',
                  subtitle: _missedOnly ? 'You picked up every call. Nice!' : 'Voice and video calls you make or receive will appear here.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 300) _load(more: true);
                      return false;
                    },
                    child: ListView.builder(
                      itemCount: calls.length,
                      itemBuilder: (_, i) => _tile(calls[i]),
                    ),
                  ),
                ),
    );
  }

  Widget _tile(CallInfo c) {
    final peer = c.peer;
    final red = c.missed;
    final arrow = c.outgoing ? Icons.call_made : (red ? Icons.call_missed : Icons.call_received);
    final arrowColor = red ? Colors.red : (c.status == 'ended' ? Brand.accent : Theme.of(context).disabledColor);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Avatar(id: c.peerId, name: peer?.name ?? '?', url: peer?.avatarAbsolute, size: 50),
      title: Text(peer?.name ?? 'Deleted Account', style: TextStyle(fontWeight: FontWeight.w700, color: red ? Colors.red : null)),
      subtitle: Row(children: [
        Icon(arrow, size: 16, color: arrowColor),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${c.label} · ${chatListTime(c.createdAt)}${c.durationSec > 0 ? ' · ${formatCallDuration(c.durationSec)}' : ''}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
      trailing: peer == null || peer.deleted
          ? null
          : IconButton(
              style: IconButton.styleFrom(backgroundColor: Brand.primary.withValues(alpha: 0.1)),
              icon: Icon(c.video ? Icons.videocam_rounded : Icons.call_rounded, color: Brand.primary, size: 21),
              onPressed: () => startCall(context, peer, video: c.video),
            ),
      onLongPress: () async {
        if (await confirm(context, 'Delete from call history?', '', ok: 'Delete', danger: true)) _delete(c);
      },
    );
  }
}

/// Call log entry inside a chat ("Outgoing call · 3:21"); tap to call back.
class CallLogBubble extends StatelessWidget {
  const CallLogBubble({super.key, required this.message, required this.isMine, required this.peer, required this.accent});
  final Message message;
  final bool isMine;
  final AppUser? peer;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final c = message.callMeta ?? const {};
    final video = c['video'] == true;
    final status = '${c['status'] ?? ''}';
    final sec = (c['duration_sec'] as num?)?.toInt() ?? 0;
    final missed = status == 'missed' || status == 'busy';
    String title;
    if (isMine) {
      title = missed ? (status == 'busy' ? 'Line busy' : 'Cancelled call') : status == 'declined' ? 'Call declined' : (video ? 'Outgoing video call' : 'Outgoing call');
    } else {
      title = missed ? (video ? 'Missed video call' : 'Missed call') : status == 'declined' ? 'Declined call' : (video ? 'Incoming video call' : 'Incoming call');
    }
    final red = !isMine && missed;
    return InkWell(
      onTap: peer == null ? null : () => startCall(context, peer!, video: video),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: (red ? Colors.red : accent).withAlpha(30),
            child: Icon(video ? Icons.videocam : Icons.call, color: red ? Colors.red : accent, size: 20),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: red ? Colors.red : null)),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(isMine ? Icons.call_made : (red ? Icons.call_missed : Icons.call_received), size: 14, color: red ? Colors.red : Brand.accent),
              const SizedBox(width: 3),
              Text(sec > 0 ? formatCallDuration(sec) : (status == 'failed' ? 'Failed' : ''), style: const TextStyle(fontSize: 12.5)),
            ]),
          ]),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }
}


// ================================================================== call links
/// The web address of a call link (opens the app; works in any chat or SMS).
String callLinkUrl(String code) => '${AppConfig.serverUrl}/call/$code';

/// Reads the code from talvio://call/<code> or https://…/call/<code>.
String? callCodeFromLink(String s) {
  final m = RegExp(r'^(?:talvio://call/|https?://[^/\s]+/call/)([A-Za-z0-9_-]{6,24})/?$').firstMatch(s.trim());
  return m?.group(1);
}

/// Someone opened a call link: show who it calls, then call them.
Future<void> openCallLink(BuildContext context, String code) async {
  final store = context.read<ChatStore>();
  final calls = context.read<CallManager>();
  try {
    final (user, video, mine) = await store.resolveCallLink(code);
    if (!context.mounted) return;
    if (mine) {
      showInfo(context, 'This is your own call link — share it so others can call you');
      return;
    }
    final go = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Avatar(id: user.id, name: user.name, url: user.avatarAbsolute, size: 72),
            const SizedBox(height: 12),
            Text(user.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(video ? 'Call link · video call' : 'Call link · voice call', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 18),
            AuroraButton(label: 'Call now', icon: video ? Icons.videocam_rounded : Icons.call_rounded, onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    );
    if (go != true || !context.mounted) return;
    if (calls.active) {
      showInfo(context, 'Finish your current call first');
      return;
    }
    await calls.start(user, video: video, link: code);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// My call links: anyone with the link can call me (even if my calls are limited to contacts).
class CallLinksScreen extends StatefulWidget {
  const CallLinksScreen({super.key});

  @override
  State<CallLinksScreen> createState() => _CallLinksScreenState();
}

class _CallLinksScreenState extends State<CallLinksScreen> {
  List<Map<String, dynamic>>? _links;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await context.read<ChatStore>().callLinks();
      if (mounted) setState(() => _links = l);
    } catch (e) {
      if (mounted) {
        setState(() => _links = const []);
        showError(context, e);
      }
    }
  }

  Future<void> _create(bool video) async {
    setState(() => _busy = true);
    try {
      final l = await context.read<ChatStore>().createCallLink(video: video);
      await Clipboard.setData(ClipboardData(text: callLinkUrl('${l['code']}')));
      if (mounted) showInfo(context, 'Link created and copied — paste it in any chat');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final links = _links;
    return Scaffold(
      appBar: AppBar(title: const Text('Call links')),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Text(
            'Share a link and anyone who has it can call you with one tap — even when “Who can call me” is set to contacts. People you block still can’t.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.call_rounded, color: Brand.green, title: 'New voice call link', onTap: _busy ? null : () => _create(false)),
          SettingsTile(icon: Icons.videocam_rounded, color: Brand.sky, title: 'New video call link', onTap: _busy ? null : () => _create(true)),
        ]),
        if (links == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (links.isNotEmpty)
          SettingsGroup(title: 'My links', children: [
            for (final l in links)
              SettingsTile(
                icon: l['video'] == true ? Icons.videocam_rounded : Icons.call_rounded,
                color: Brand.primary,
                title: callLinkUrl('${l['code']}'),
                subtitle: '${l['video'] == true ? 'Video' : 'Voice'} · tap to copy',
                maxSubtitleLines: 1,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: callLinkUrl('${l['code']}')));
                  showInfo(context, 'Link copied');
                },
                trailingWidget: IconButton(
                  tooltip: 'Delete link',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    if (!await confirm(context, 'Delete this link?', 'People who have it won’t be able to use it anymore.', ok: 'Delete', danger: true)) return;
                    try {
                      if (!context.mounted) return;
                      await context.read<ChatStore>().deleteCallLink('${l['code']}');
                      await _load();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                ),
              ),
          ]),
      ]),
    );
  }
}
