import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_state.dart';
import '../theme/brand.dart';

/// The emoji next to someone's name (nothing when they have none).
class EmojiStatusBadge extends StatelessWidget {
  const EmojiStatusBadge(this.user, {super.key, this.size = 16, this.padLeft = 4});
  final AppUser? user;
  final double size;
  final double padLeft;

  @override
  Widget build(BuildContext context) {
    final e = user?.statusEmoji;
    if (e == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(left: padLeft),
      child: Text(e, style: TextStyle(fontSize: size, height: 1.1)),
    );
  }
}

const _groups = <String, List<String>>{
  'Mood': ['😀', '😎', '🥳', '😴', '🤒', '🤔', '😇', '🤩', '😡', '🥲', '😌', '🫡', '🤯', '🥶', '🤫', '😈'],
  'Busy': ['💼', '💻', '📚', '✍️', '📞', '🎧', '🚗', '✈️', '🏋️', '🏃', '🍽️', '☕', '🕌', '🛌', '🎮', '🔕'],
  'Vibes': ['🔥', '⭐', '💎', '🚀', '❤️', '💯', '⚡', '🌙', '☀️', '🌈', '🍀', '🎯', '👑', '🏆', '💰', '📈'],
  'Places': ['🇵🇰', '🇸🇦', '🇦🇪', '🇬🇧', '🇺🇸', '🇹🇷', '🏖️', '🏔️', '🏠', '🏢', '🎓', '🏏', '⚽', '🎬', '🎵', '📸'],
};

const _durations = <String, Duration?>{
  'Until I change it': null,
  '1 hour': Duration(hours: 1),
  '8 hours': Duration(hours: 8),
  '1 day': Duration(days: 1),
  '2 days': Duration(days: 2),
  '1 week': Duration(days: 7),
};

/// Pick (or remove) my emoji status.
Future<void> showEmojiStatusPicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _Picker(),
  );
}

class _Picker extends StatefulWidget {
  const _Picker();

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String _duration = 'Until I change it';
  bool _busy = false;

  Future<void> _set(String? emoji) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AuthState>().setEmojiStatus(emoji, duration: _durations[_duration]);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = context.watch<AuthState>().me?.statusEmoji;
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(children: [
              const Expanded(child: Text('Emoji status', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
              if (current != null)
                TextButton.icon(
                  onPressed: _busy ? null : () => _set(null),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Remove'),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Shown next to your name everywhere in Hushavia.', style: TextStyle(color: muted, fontSize: 13)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final d in _durations.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(d),
                      selected: _duration == d,
                      onSelected: (_) => setState(() => _duration = d),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 16), children: [
              for (final g in _groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
                  child: Text(g.key.toUpperCase(), style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                ),
                GridView.count(
                  crossAxisCount: 8,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final e in g.value)
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _busy ? null : () => _set(e),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: e == current
                              ? BoxDecoration(color: Brand.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12))
                              : null,
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
