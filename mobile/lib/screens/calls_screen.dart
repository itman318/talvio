import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/call_manager.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';

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
      setState(() => _calls?.removeWhere((x) => x.id == c.id));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _clearAll() async {
    if (!await confirm(context, 'Clear call history?', 'This only clears your list.', ok: 'Clear', danger: true)) return;
    if (!mounted) return;
    try {
      await context.read<AppServices>().api.post('/calls/delete', {'all': true});
      setState(() => _calls = []);
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
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.call_outlined, size: 64, color: Theme.of(context).disabledColor),
                    const SizedBox(height: 8),
                    Text(_missedOnly ? 'No missed calls' : 'No calls yet'),
                  ]),
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
    final arrowColor = red ? Colors.red : (c.status == 'ended' ? Colors.green : Theme.of(context).disabledColor);
    return ListTile(
      leading: Avatar(id: c.peerId, name: peer?.name ?? '?', url: peer?.avatarAbsolute, size: 46),
      title: Text(peer?.name ?? 'Deleted Account', style: TextStyle(color: red ? Colors.red : null)),
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
              icon: Icon(c.video ? Icons.videocam_outlined : Icons.call_outlined, color: const Color(0xFF2AABEE)),
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
              Icon(isMine ? Icons.call_made : (red ? Icons.call_missed : Icons.call_received), size: 14, color: red ? Colors.red : Colors.green),
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
