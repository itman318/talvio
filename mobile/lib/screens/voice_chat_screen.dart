import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/voice_chat_manager.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';

/// Opens (and if needed joins / starts) the voice chat of [chat].
Future<void> openVoiceChat(BuildContext context, Chat chat, {bool start = false}) async {
  final vc = context.read<VoiceChatManager>();
  if (vc.chatId != chat.id) {
    var title = '';
    if (start) {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Start a voice chat'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(chat.isChannel
                ? 'Talk live with your subscribers. They listen and can raise a hand to speak.'
                : 'Everyone in the group can join and talk.'),
            const SizedBox(height: 12),
            TextField(controller: c, maxLength: 64, decoration: const InputDecoration(labelText: 'Topic (optional)', hintText: 'Gold market live')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
          ],
        ),
      );
      if (ok != true) return;
      title = c.text.trim();
    }
    try {
      await vc.join(chat, start: start, title: title);
    } catch (e) {
      if (context.mounted) {
        final s = '$e'.toLowerCase();
        showInfo(context, s.contains('permission') || s.contains('notallowed') ? 'Allow microphone access to join voice chats' : friendlyError(e));
      }
      return;
    }
  }
  if (context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const VoiceChatScreen()));
}

class VoiceChatScreen extends StatelessWidget {
  const VoiceChatScreen({super.key});

  Future<void> _manage(BuildContext context, VoiceChatManager vc, VcParticipant p) async {
    if (!vc.canManage || p.user.id == vc.me?.user.id) return;
    final a = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1D33),
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: Avatar(id: p.user.id, name: p.user.name, url: p.user.avatarAbsolute, size: 36),
            title: Text(p.user.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          if (!p.muted)
            ListTile(
              leading: const Icon(Icons.mic_off_rounded, color: Colors.white),
              title: const Text('Mute', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
          if (!p.canSpeak)
            ListTile(
              leading: const Icon(Icons.record_voice_over_rounded, color: Colors.white),
              title: Text(p.handRaised ? 'Let them speak (hand raised)' : 'Let them speak', style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'speak'),
            )
          else
            ListTile(
              leading: const Icon(Icons.voice_over_off_rounded, color: Colors.white),
              title: const Text('Make a listener', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'listener'),
            ),
        ]),
      ),
    );
    try {
      if (a == 'mute') await vc.manage(p.user.id, mute: true);
      if (a == 'speak') await vc.manage(p.user.id, canSpeak: true);
      if (a == 'listener') await vc.manage(p.user.id, canSpeak: false);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.watch<VoiceChatManager>();
    if (!vc.active && !vc.connecting) {
      // ended or left: close the screen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.canPop(context)) Navigator.pop(context);
      });
    }
    final me = vc.me;
    final speakers = vc.participants.where((p) => p.canSpeak).toList();
    final listeners = vc.participants.where((p) => !p.canSpeak).toList();
    return Scaffold(
      backgroundColor: const Color(0xFF0E1022),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(vc.title.isNotEmpty ? vc.title : 'Voice chat', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          Text('${vc.chatTitle} · ${vc.participants.length} ${vc.participants.length == 1 ? 'participant' : 'participants'}',
              style: const TextStyle(fontSize: 12.5, color: Colors.white60)),
        ]),
        actions: [
          if (vc.canManage)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) async {
                if (v == 'end' &&
                    await confirm(context, 'End voice chat?', 'Everyone will be disconnected.', ok: 'End', danger: true)) {
                  await vc.end();
                }
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'end', child: Text('End voice chat for everyone'))],
            ),
        ],
      ),
      body: Stack(children: [
        // soft aurora glow
        Positioned(top: -120, left: -80, child: _glow(const Color(0xFF8E54E9), 320)),
        Positioned(bottom: 40, right: -100, child: _glow(const Color(0xFFFF5E8A), 300)),
        if (vc.connecting)
          const Center(child: CircularProgressIndicator(color: Colors.white))
        else
          ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 200), children: [
            if (speakers.isNotEmpty) _section('Speakers'),
            Wrap(spacing: 14, runSpacing: 18, children: [for (final p in speakers) _tile(context, vc, p)]),
            if (listeners.isNotEmpty) ...[
              const SizedBox(height: 22),
              _section('Listening'),
              Wrap(spacing: 14, runSpacing: 18, children: [for (final p in listeners) _tile(context, vc, p, small: true)]),
            ],
          ]),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, crossAxisAlignment: CrossAxisAlignment.end, children: [
                _round(
                  icon: vc.speaker ? Icons.volume_up_rounded : Icons.hearing_rounded,
                  label: vc.speaker ? 'Speaker' : 'Earpiece',
                  onTap: vc.toggleSpeaker,
                ),
                _bigMic(context, vc, me),
                _round(
                  icon: Icons.call_end_rounded,
                  label: 'Leave',
                  color: const Color(0xFFE5484D),
                  onTap: () async {
                    await vc.leave();
                    if (context.mounted && Navigator.canPop(context)) Navigator.pop(context);
                  },
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  static Widget _glow(Color c, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [c.withValues(alpha: 0.35), c.withValues(alpha: 0)])),
        ),
      );

  static Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 4),
        child: Text(t.toUpperCase(), style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
      );

  Widget _tile(BuildContext context, VoiceChatManager vc, VcParticipant p, {bool small = false}) {
    final size = small ? 58.0 : 76.0;
    final isMe = p.user.id == vc.me?.user.id;
    return GestureDetector(
      onTap: () => _manage(context, vc, p),
      child: SizedBox(
        width: size + 18,
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: p.speaking ? Brand.aurora : null,
                color: p.speaking ? null : Colors.white.withValues(alpha: 0.08),
                boxShadow: p.speaking ? [BoxShadow(color: const Color(0xFFFF5E8A).withValues(alpha: 0.55), blurRadius: 18, spreadRadius: 2)] : null,
              ),
              child: ClipOval(child: Avatar(id: p.user.id, name: p.user.name, url: p.user.avatarAbsolute, size: size)),
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.handRaised ? Brand.amber : (p.muted ? const Color(0xFF2A2E48) : const Color(0xFF12A150)),
                  border: Border.all(color: const Color(0xFF0E1022), width: 2),
                ),
                child: Icon(p.handRaised ? Icons.back_hand_rounded : (p.muted ? Icons.mic_off_rounded : Icons.mic_rounded), size: 13, color: Colors.white),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(isMe ? 'You' : p.user.firstName.isNotEmpty ? p.user.firstName : p.user.name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          Text(p.handRaised ? 'wants to speak' : (p.speaking ? 'speaking' : (p.muted ? (p.canSpeak ? 'muted' : 'listening') : 'unmuted')),
              style: TextStyle(color: p.speaking ? const Color(0xFF7DF3DB) : Colors.white38, fontSize: 11.5)),
        ]),
      ),
    );
  }

  Widget _round({required IconData icon, required String label, required VoidCallback onTap, Color? color}) => Column(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: color ?? Colors.white.withValues(alpha: 0.1),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 56, height: 56, child: Icon(icon, color: Colors.white, size: 24)),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]);

  Widget _bigMic(BuildContext context, VoiceChatManager vc, VcParticipant? me) {
    final canSpeak = me?.canSpeak ?? false;
    final muted = me?.muted ?? true;
    final hand = me?.handRaised ?? false;
    final label = !canSpeak ? (hand ? 'Hand raised' : 'Raise hand') : (muted ? 'Unmute' : 'Mute');
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: () async {
          try {
            await vc.toggleMute();
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: !canSpeak
                ? const LinearGradient(colors: [Color(0xFFFFB347), Color(0xFFF09819)])
                : (muted ? const LinearGradient(colors: [Color(0xFF3B3F63), Color(0xFF2A2E48)]) : Brand.aurora),
            boxShadow: [
              BoxShadow(
                color: (!muted && canSpeak ? const Color(0xFFFF5E8A) : Colors.black).withValues(alpha: 0.4),
                blurRadius: me?.speaking == true ? 30 : 16,
                spreadRadius: me?.speaking == true ? 4 : 0,
              ),
            ],
          ),
          child: Icon(!canSpeak ? Icons.back_hand_rounded : (muted ? Icons.mic_off_rounded : Icons.mic_rounded), color: Colors.white, size: 40),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
    ]);
  }
}

/// Thin bar above the bottom navigation while I'm in a voice chat (tap to open it).
class VoiceChatMiniBar extends StatelessWidget {
  const VoiceChatMiniBar({super.key});

  @override
  Widget build(BuildContext context) {
    final vc = context.watch<VoiceChatManager>();
    if (!vc.active) return const SizedBox.shrink();
    final speaking = vc.participants.where((p) => p.speaking).map((p) => p.user.firstName).take(2).join(', ');
    return Material(
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VoiceChatScreen())),
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(gradient: Brand.aurora),
          child: Row(children: [
            const Icon(Icons.graphic_eq_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                speaking.isNotEmpty ? '$speaking speaking · ${vc.chatTitle}' : 'Voice chat · ${vc.chatTitle} · ${vc.participants.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: vc.muted ? 'Unmute' : 'Mute',
              icon: Icon(vc.muted ? Icons.mic_off_rounded : Icons.mic_rounded, color: Colors.white),
              onPressed: () => vc.toggleMute().catchError((_) {}),
            ),
            IconButton(tooltip: 'Leave', icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: vc.leave),
          ]),
        ),
      ),
    );
  }
}
