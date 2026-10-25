import 'package:flutter/material.dart';
import 'message_extras.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import 'avatar.dart';
import '../theme/brand.dart';

/// Poll / quiz inside a message bubble: vote, see results, quiz feedback.
class PollView extends StatefulWidget {
  const PollView({super.key, required this.message, required this.accent});
  final Message message;
  final Color accent;

  @override
  State<PollView> createState() => _PollViewState();
}

class _PollViewState extends State<PollView> {
  final Set<int> _picked = {};
  bool _busy = false;

  Future<void> _vote(List<int> options) async {
    setState(() => _busy = true);
    try {
      await context.read<ChatStore>().vote(widget.message, options);
      _picked.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showVoters(int option) async {
    final p = widget.message.poll!;
    try {
      final users = await context.read<ChatStore>().pollVoters(widget.message, option);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(p.options[option].text, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (users.isEmpty) const ListTile(title: Text('No votes yet')),
              ...users.map((u) => ListTile(leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 36), title: Text(u.name))),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.message.poll;
    if (p == null) return const Text('Poll');
    final accent = widget.accent;
    final results = p.showResults;
    final total = p.options.fold<int>(0, (s, o) => s + o.votes);
    final kind = p.quiz ? 'Quiz' : (p.anonymous ? 'Anonymous poll' : 'Public poll');

    return SizedBox(
      width: 250,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.question, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(p.isClosed ? 'Final results · $kind' : (p.closeAt != null ? '$kind · ${_endsIn(p.closeAt!)}' : kind),
              style: const TextStyle(fontSize: 12, color: Brand.muted)),
          const SizedBox(height: 8),
          for (var i = 0; i < p.options.length; i++) _option(p, i, results, total, accent),
          if (p.multiple && !results && !p.isClosed)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _picked.isEmpty || _busy ? null : () => _vote(_picked.toList()),
                child: const Text('Vote'),
              ),
            ),
          if (p.quiz && p.explanation != null && p.explanation!.isNotEmpty && results)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('💡 ${p.explanation}', style: const TextStyle(fontSize: 13)),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('${p.totalVoters} ${p.totalVoters == 1 ? 'vote' : 'votes'}', style: const TextStyle(fontSize: 12, color: Brand.muted)),
              const Spacer(),
              if (p.voted && !p.quiz && !p.isClosed)
                GestureDetector(
                  onTap: _busy ? null : () => _vote([]),
                  child: Text('Retract vote', style: TextStyle(fontSize: 12, color: accent)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _option(PollInfo p, int i, bool results, int total, Color accent) {
    final o = p.options[i];
    final pct = total == 0 ? 0.0 : o.votes / total;
    final mine = p.myVotes.contains(i);
    final correct = p.quiz && p.correctOption == i;
    final wrongPick = p.quiz && mine && p.correctOption != null && p.correctOption != i;
    final barColor = p.quiz && results ? (correct ? Brand.accent : (wrongPick ? Colors.red : accent)) : accent;

    if (!results && !p.isClosed) {
      return InkWell(
        onTap: _busy
            ? null
            : () {
                if (p.multiple) {
                  setState(() => _picked.contains(i) ? _picked.remove(i) : _picked.add(i));
                } else {
                  _vote([i]);
                }
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(
              p.multiple ? (_picked.contains(i) ? Icons.check_box : Icons.check_box_outline_blank) : Icons.radio_button_unchecked,
              size: 20,
              color: accent,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(o.text)),
          ]),
        ),
      );
    }
    return InkWell(
      onTap: p.anonymous ? null : () => _showVoters(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              SizedBox(width: 40, child: Text('${(pct * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              Expanded(child: Text(o.text)),
              if (mine) Icon(wrongPick ? Icons.cancel : Icons.check_circle, size: 16, color: barColor),
              if (correct && !mine) const Icon(Icons.check_circle_outline, size: 16, color: Brand.accent),
            ]),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: pct, minHeight: 5, color: barColor, backgroundColor: barColor.withAlpha(30)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reaction chips under a message; tapping one toggles your own reaction.
class ReactionChips extends StatelessWidget {
  const ReactionChips({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: message.reactions.map((r) => _ReactionChip(message: message, emoji: r.emoji, count: r.count)).toList(),
      ),
    );
  }
}

/// One reaction pill: pops when its count changes; tapping it toggles your reaction (with a burst).
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.message, required this.emoji, required this.count});
  final Message message;
  final String emoji;
  final int count;

  @override
  Widget build(BuildContext context) {
    final mine = message.myReaction == emoji;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        if (!mine) {
          final box = context.findRenderObject() as RenderBox?;
          final at = box == null ? null : box.localToGlobal(box.size.center(Offset.zero));
          showReactionBurst(context, emoji, at: at);
        }
        context.read<ChatStore>().react(message, emoji).catchError((e) {
          if (context.mounted) showError(context, e);
        });
      },
      child: TweenAnimationBuilder<double>(
        key: ValueKey('$emoji$count$mine'),
        tween: Tween(begin: 0.6, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.elasticOut,
        builder: (_, s, child) => Transform.scale(scale: s, child: child),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            gradient: mine ? Brand.aurora : null,
            color: mine ? null : (dark ? Colors.white.withAlpha(28) : Colors.black.withAlpha(14)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text('$emoji $count',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mine ? Colors.white : (dark ? Colors.white : Colors.black87))),
        ),
      ),
    );
  }
}


/// "ends in 2h 15m" / "ends in 3 days".
String _endsIn(DateTime at) {
  final d = at.difference(DateTime.now());
  if (d.isNegative) return 'closing…';
  if (d.inDays >= 2) return 'ends in ${d.inDays} days';
  if (d.inHours >= 1) return 'ends in ${d.inHours}h ${d.inMinutes % 60}m';
  return 'ends in ${d.inMinutes.clamp(1, 59)} min';
}
